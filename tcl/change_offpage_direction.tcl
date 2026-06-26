# coco-connect-capture change_offpage_direction bridge implementation (M2).
#
# Flips the orientation ("direction") of off-page connectors selected by name.
# Agent-facing companion to list_offpage_connectors (list-then-act).
#
# OrCAD encodes an off-page connector's direction in its symbol + MIRROR state;
# the connector points one way (e.g. OFFPAGELEFT-L) and mirroring it horizontally
# reverses which side it points. The benchmark change_dir_offpage.tcl achieved
# this by DELETE + re-PLACE via UI commands; probe_offpage_direction.tcl found a
# clean in-place path: DboOffPageConnector exposes SetMirror, so flipping
# direction is just toggling the mirror flag (no UI automation, no delete/place).
#
# mode: dry_run (default, plan only) | apply (SetMirror + MarkModified).
# scope: all (default, every page) | active_page.

namespace eval ::change_offpage_direction {
}

proc ::change_offpage_direction::_get_name {obj} {
    if {[catch {set c [DboTclHelper_sMakeCString]}]} { return "" }
    if {[catch {$obj GetName $c}]} { return "" }
    return [string trim [DboTclHelper_sGetConstCharPtr $c]]
}

# Current mirror flag (0/1). Returns "" if unreadable.
proc ::change_offpage_direction::_get_mirror {obj status} {
    if {[catch {set m [$obj GetMirror $status]}]} {
        if {[catch {set m [$obj GetMirror]}]} { return "" }
    }
    return $m
}

# Symbol name (e.g. OFFPAGELEFT-L), "" if unavailable.
proc ::change_offpage_direction::_get_symbol_name {obj status} {
    if {[catch {set sym [$obj GetSymbol $status]}]} {
        if {[catch {set sym [$obj GetSymbol]}]} { return "" }
    }
    if {$sym eq "" || [::coco_capture_utils::is_null $sym]} { return "" }
    if {[catch {set c [DboTclHelper_sMakeCString]}]} { return "" }
    if {[catch {$sym GetName $c}]} { return "" }
    return [string trim [DboTclHelper_sGetConstCharPtr $c]]
}

# Apply the mirror flip in place (try status-arg then no-arg signature).
proc ::change_offpage_direction::_set_mirror {obj value status} {
    if {[catch {$obj SetMirror $value $status}]} {
        if {[catch {$obj SetMirror $value}]} { return 0 }
    }
    catch {$obj MarkModified}
    catch {$obj SetBoundingBoxDirty 1}
    return 1
}

proc ::change_offpage_direction::_active_page_name {} {
    if {![::coco_capture_utils::cmd_exists GetActivePage]} { return "" }
    if {[catch {set page [GetActivePage]}]} { return "" }
    if {[::coco_capture_utils::is_null $page]} { return "" }
    return [::coco_capture_utils::name $page]
}

proc ::change_offpage_direction::_flip_obj {name page_path old_mirror new_mirror symbol} {
    return [::coco_capture_utils::json_object_from_pairs [list \
        [::coco_capture_utils::json_field_string name $name] \
        [::coco_capture_utils::json_field_string page_path $page_path] \
        [::coco_capture_utils::json_field_number old_mirror $old_mirror] \
        [::coco_capture_utils::json_field_number new_mirror $new_mirror] \
        [::coco_capture_utils::json_field_string symbol $symbol]]]
}

# names_spec: comma-separated connector names to flip.
proc ::change_offpage_direction::change_direction {mode scope names_spec} {
    set apply [expr {$mode eq "apply"}]
    if {$scope ne "active_page"} { set scope "all" }

    set names [dict create]
    foreach n [split $names_spec ","] {
        set n [string trim $n]
        if {$n ne ""} { dict set names $n 1 }
    }
    if {[dict size $names] == 0} {
        error [::coco_capture_utils::json_error "invalid_arg" \
            "at least one connector name is required" \
            [::coco_capture_utils::json_object_from_pairs [list \
                [::coco_capture_utils::json_field_string command "change_offpage_direction"]]]]
    }

    set status [::coco_capture_utils::status]
    set session [::coco_capture_utils::session]
    set design [::coco_capture_utils::active_design $session $status]
    set null_obj "NULL"

    set active_page_name ""
    if {$scope eq "active_page"} {
        set active_page_name [_active_page_name]
        if {$active_page_name eq ""} { set scope "all" }
    }

    set flips {}
    set matched_names [dict create]
    set scanned 0

    set schem_iter [::coco_capture_utils::schem_iter $design $status]
    while {1} {
        if {[catch {set view [$schem_iter NextView $status]}]} { break }
        if {$view eq $null_obj} { break }
        set schematic [::coco_capture_utils::to_schematic $view]
        set schematic_name [::coco_capture_utils::name $schematic]
        if {[catch {set pages_iter [$schematic NewPagesIter $status]}]} { continue }
        while {1} {
            if {[catch {set page [$pages_iter NextPage $status]}]} { break }
            if {$page eq $null_obj} { break }
            set page_name [::coco_capture_utils::name $page]
            if {$active_page_name ne "" && ![string equal $page_name $active_page_name]} { continue }
            set page_path [::coco_capture_utils::page_path $schematic_name $page_name]

            if {[catch {set it [$page NewOffPageConnectorsIter $status]}]} { continue }
            while {1} {
                if {[catch {set obj [$it NextOffPageConnector $status]}]} { break }
                if {$obj eq $null_obj} { break }
                set nm [_get_name $obj]
                if {$nm eq ""} { continue }
                incr scanned
                if {![dict exists $names $nm]} { continue }
                dict set matched_names $nm 1
                set mirror [_get_mirror $obj $status]
                if {$mirror eq ""} { continue }
                set new_mirror [expr {$mirror ? 0 : 1}]
                set symbol [_get_symbol_name $obj $status]
                if {$apply} {
                    _set_mirror $obj $new_mirror $status
                }
                lappend flips [_flip_obj $nm $page_path $mirror $new_mirror $symbol]
            }
            ::coco_capture_utils::safe_delete delete_DboPageOffPageConnectorsIter $it
        }
        ::coco_capture_utils::safe_delete delete_DboSchematicPagesIter $pages_iter
    }
    ::coco_capture_utils::safe_delete delete_DboLibViewsIter $schem_iter

    set not_found {}
    foreach n [dict keys $names] {
        if {![dict exists $matched_names $n]} {
            lappend not_found [::coco_capture_utils::json_quote $n]
        }
    }

    set data [::coco_capture_utils::json_object_from_pairs [list \
        [::coco_capture_utils::json_field_string command "change_offpage_direction"] \
        [::coco_capture_utils::json_field_string mode [expr {$apply ? "apply" : "dry_run"}]] \
        [::coco_capture_utils::json_field_string scope $scope] \
        [::coco_capture_utils::json_field_bool applied $apply] \
        [::coco_capture_utils::json_field_number scanned_connectors $scanned] \
        [::coco_capture_utils::json_field_number flip_count [llength $flips]] \
        [::coco_capture_utils::json_field_json flips \
            [::coco_capture_utils::json_array_from_values $flips]] \
        [::coco_capture_utils::json_field_json not_found \
            [::coco_capture_utils::json_array_from_values $not_found]]]]
    return [::coco_capture_utils::json_success $data]
}

# Impl entry: arg = mode|scope|name1,name2,...
#   mode:  dry_run (default) | apply
#   scope: all (default) | active_page
proc ::coco_capture_change_offpage_direction_impl {arg} {
    set parts [split $arg "|"]
    set mode [lindex $parts 0]
    set scope [lindex $parts 1]
    set names_spec [lindex $parts 2]
    if {$mode eq ""} { set mode "dry_run" }
    if {$scope eq ""} { set scope "all" }
    return [::change_offpage_direction::change_direction $mode $scope $names_spec]
}
