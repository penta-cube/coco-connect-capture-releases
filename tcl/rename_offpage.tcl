# coco-connect-capture rename_offpage_connectors bridge implementation (M2).
#
# Renames off-page connectors by an old->new name mapping. Agent-facing companion
# to list_offpage_connectors (list-then-act): the agent lists connectors, then
# renames by name. Replaces the benchmark replace_offpage.tcl's CSV/coordinate
# matching with a direct name mapping.
#
# Off-page connectors join across pages by name, so the default scope is `all`
# (rename a net everywhere to preserve connectivity); `active_page` allows an
# intentional single-page split.
#
# mode: dry_run (default, plan only) | apply (SetName + MarkModified).
# Safety (atomic): if any conflict (a target name would merge with a kept net, or
# two sources map to one target) or any rename cycle (A->B,B->A) is detected, the
# apply is refused entirely (nothing is mutated) and the report explains why.

namespace eval ::rename_offpage {
}

# Parse "old1=new1,old2=new2" into a dict old->new (first '=' splits each pair).
proc ::rename_offpage::_parse_mapping {spec} {
    set map [dict create]
    foreach pair [split $spec ","] {
        set pair [string trim $pair]
        if {$pair eq ""} { continue }
        set idx [string first "=" $pair]
        if {$idx < 0} { continue }
        set old [string trim [string range $pair 0 [expr {$idx - 1}]]]
        set new [string trim [string range $pair [expr {$idx + 1}] end]]
        if {$old ne "" && $new ne ""} { dict set map $old $new }
    }
    return $map
}

# Connector name via GetName.
proc ::rename_offpage::_get_name {obj} {
    if {[catch {set c [DboTclHelper_sMakeCString]}]} { return "" }
    if {[catch {$obj GetName $c}]} { return "" }
    return [string trim [DboTclHelper_sGetConstCharPtr $c]]
}

# Does following old->new (while the value is itself a key) revisit a node? If so
# the mapping contains a cycle (e.g. A->B, B->A).
proc ::rename_offpage::_has_cycle {map} {
    foreach start [dict keys $map] {
        set seen [dict create]
        set node $start
        while {[dict exists $map $node]} {
            if {[dict exists $seen $node]} { return 1 }
            dict set seen $node 1
            set node [dict get $map $node]
        }
    }
    return 0
}

proc ::rename_offpage::_active_page_name {} {
    if {![::coco_capture_utils::cmd_exists GetActivePage]} { return "" }
    if {[catch {set page [GetActivePage]}]} { return "" }
    if {[::coco_capture_utils::is_null $page]} { return "" }
    return [::coco_capture_utils::name $page]
}

proc ::rename_offpage::_rename_obj {old new page_path} {
    return [::coco_capture_utils::json_object_from_pairs [list \
        [::coco_capture_utils::json_field_string old $old] \
        [::coco_capture_utils::json_field_string new $new] \
        [::coco_capture_utils::json_field_string page_path $page_path]]]
}

proc ::rename_offpage::_conflict_obj {old new reason} {
    return [::coco_capture_utils::json_object_from_pairs [list \
        [::coco_capture_utils::json_field_string old $old] \
        [::coco_capture_utils::json_field_string new $new] \
        [::coco_capture_utils::json_field_string reason $reason]]]
}

proc ::rename_offpage::rename_offpage {mode scope mapping_spec} {
    set apply [expr {$mode eq "apply"}]
    if {$scope ne "active_page"} { set scope "all" }
    set map [_parse_mapping $mapping_spec]
    if {[dict size $map] == 0} {
        error [::coco_capture_utils::json_error "invalid_arg" \
            "mapping is required (old=new[,old=new...])" \
            [::coco_capture_utils::json_object_from_pairs [list \
                [::coco_capture_utils::json_field_string command "rename_offpage_connectors"]]]]
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

    # Pass 1: collect connector objects + names across scope. Capturing object
    # handles up front means a swap (A<->B) renames the right objects regardless
    # of order; only true cycles are rejected (see _has_cycle).
    set matches {}
    set existing [dict create]
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
                dict incr existing $nm
                if {[dict exists $map $nm]} {
                    lappend matches [list $nm [dict get $map $nm] $page_path $obj]
                }
            }
            ::coco_capture_utils::safe_delete delete_DboPageOffPageConnectorsIter $it
        }
        ::coco_capture_utils::safe_delete delete_DboSchematicPagesIter $pages_iter
    }
    ::coco_capture_utils::safe_delete delete_DboLibViewsIter $schem_iter

    # Validation: conflicts (merges) + cycle.
    set keys [dict keys $map]
    set target_count [dict create]
    foreach k $keys { dict incr target_count [dict get $map $k] }

    set conflicts {}
    foreach k $keys {
        set new [dict get $map $k]
        # target collides with a kept net (exists and is not itself renamed away)
        if {[dict exists $existing $new] && [lsearch -exact $keys $new] < 0} {
            lappend conflicts [_conflict_obj $k $new "target_exists"]
        }
        # two sources map to the same target
        if {[dict get $target_count $new] > 1} {
            lappend conflicts [_conflict_obj $k $new "duplicate_target"]
        }
    }
    set cycle [_has_cycle $map]

    # Mapping keys that matched no connector in scope.
    set matched_olds [dict create]
    foreach m $matches { dict set matched_olds [lindex $m 0] 1 }
    set not_found {}
    foreach k $keys {
        if {![dict exists $matched_olds $k]} {
            lappend not_found [::coco_capture_utils::json_quote $k]
        }
    }

    set blocked [expr {[llength $conflicts] > 0 || $cycle}]
    set did_apply [expr {$apply && !$blocked}]

    set renames {}
    foreach m $matches {
        lassign $m old new page_path obj
        if {$did_apply} {
            catch {set nc [DboTclHelper_sMakeCString $new]}
            catch {$obj SetName $nc}
            catch {$obj MarkModified}
            catch {$obj SetBoundingBoxDirty 1}
        }
        lappend renames [_rename_obj $old $new $page_path]
    }

    set data [::coco_capture_utils::json_object_from_pairs [list \
        [::coco_capture_utils::json_field_string command "rename_offpage_connectors"] \
        [::coco_capture_utils::json_field_string mode [expr {$apply ? "apply" : "dry_run"}]] \
        [::coco_capture_utils::json_field_string scope $scope] \
        [::coco_capture_utils::json_field_bool applied $did_apply] \
        [::coco_capture_utils::json_field_bool blocked $blocked] \
        [::coco_capture_utils::json_field_bool cycle $cycle] \
        [::coco_capture_utils::json_field_number scanned_connectors $scanned] \
        [::coco_capture_utils::json_field_number rename_count [llength $renames]] \
        [::coco_capture_utils::json_field_json renames \
            [::coco_capture_utils::json_array_from_values $renames]] \
        [::coco_capture_utils::json_field_json conflicts \
            [::coco_capture_utils::json_array_from_values $conflicts]] \
        [::coco_capture_utils::json_field_json not_found \
            [::coco_capture_utils::json_array_from_values $not_found]]]]
    return [::coco_capture_utils::json_success $data]
}

# Impl entry: arg = mode|scope|old1=new1,old2=new2
#   mode:  dry_run (default) | apply
#   scope: all (default) | active_page
proc ::coco_capture_rename_offpage_connectors_impl {arg} {
    set parts [split $arg "|"]
    set mode [lindex $parts 0]
    set scope [lindex $parts 1]
    set mapping_spec [lindex $parts 2]
    if {$mode eq ""} { set mode "dry_run" }
    if {$scope eq ""} { set scope "all" }
    return [::rename_offpage::rename_offpage $mode $scope $mapping_spec]
}
