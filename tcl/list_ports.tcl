# coco-connect-capture list_ports bridge implementation (M2, increment 1).
#
# Enumerates schematic ports with name + absolute coordinates, sorted by (x, y).
# JSON-array replacement for the benchmark's copy_port.tcl (which exported the
# same name/coordinate data to CSV with X-grouping). Read-only.
#
# This is the list half of the list-then-act pattern: the M2 mutation tools
# (rename_offpage_connectors / change_offpage_direction) have no GUI selection to
# act on, so an agent must first list ports/connectors to obtain the name + page
# (+ coordinates) that parameterize those mutations.
#
# scope: active_page (default) | all (every page in the design)

namespace eval ::list_ports {
}

# Active page name, or "" when none can be determined (caller then scans all).
proc ::list_ports::_active_page_name {} {
    if {![::coco_capture_utils::cmd_exists GetActivePage]} { return "" }
    if {[catch {set page [GetActivePage]}]} { return "" }
    if {[::coco_capture_utils::is_null $page]} { return "" }
    return [::coco_capture_utils::name $page]
}

# Port absolute coords = location + bounding-box top-left offset (copy_port.tcl
# parity). Returns {x y}; {0 0} on failure. Frees the C++ point/rect temporaries.
proc ::list_ports::_abs_coords {port status} {
    set x 0
    set y 0
    set rect ""
    set tl ""
    set loc ""
    catch {
        set rect [$port GetBoundingBox]
        set tl [DboTclHelper_sGetCRectTopLeft $rect]
        set relx [DboTclHelper_sGetCPointX $tl]
        set rely [DboTclHelper_sGetCPointY $tl]
        set loc [$port GetLocation $status]
        set lx [DboTclHelper_sGetCPointX $loc]
        set ly [DboTclHelper_sGetCPointY $loc]
        set x [expr {$lx + $relx}]
        set y [expr {$ly + $rely}]
    }
    catch {DboTclHelper_sDeleteCPoint $tl}
    catch {DboTclHelper_sDeleteCPoint $loc}
    catch {DboTclHelper_sDeleteCRect $rect}
    return [list $x $y]
}

# Sort comparator over {name x y page_path} records: by x, then y (numeric).
proc ::list_ports::_cmp {a b} {
    set ax [lindex $a 1]
    set bx [lindex $b 1]
    if {$ax < $bx} { return -1 }
    if {$ax > $bx} { return 1 }
    set ay [lindex $a 2]
    set by [lindex $b 2]
    if {$ay < $by} { return -1 }
    if {$ay > $by} { return 1 }
    return 0
}

# Read page document units once (first page that exposes them). Sets the upvar'd
# units_per_inch (numeric) / is_metric (0|1); leaves them untouched on failure.
proc ::list_ports::_read_units {page upi_var metric_var} {
    upvar 1 $upi_var upi
    upvar 1 $metric_var metric
    if {$upi ne ""} { return }
    if {![catch {set u [$page GetDocUnitsPerInch]}]} {
        if {[string is double -strict $u]} { set upi $u }
    }
    if {![catch {set m [$page GetIsMetric]}]} {
        if {![catch {set mb [expr {$m ? 1 : 0}]}]} { set metric $mb }
    }
}

# Core: enumerate ports across the requested scope, sorted by (x, y).
proc ::list_ports::list_ports {scope} {
    if {$scope ne "all"} { set scope "active_page" }

    set status [::coco_capture_utils::status]
    set session [::coco_capture_utils::session]
    set design [::coco_capture_utils::active_design $session $status]
    set null_obj "NULL"

    set active_page_name ""
    if {$scope eq "active_page"} {
        set active_page_name [_active_page_name]
        if {$active_page_name eq ""} { set scope "all" }
    }

    set records {}
    set pages 0
    set units_per_inch ""
    set is_metric ""

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
            incr pages
            _read_units $page units_per_inch is_metric

            if {[catch {set ports_iter [$page NewPortsIter $status]}]} { continue }
            while {1} {
                if {[catch {set port [$ports_iter NextPort $status]}]} { break }
                if {$port eq $null_obj} { break }
                set name [::coco_capture_utils::name $port]
                lassign [_abs_coords $port $status] x y
                lappend records [list $name $x $y $page_path]
            }
            ::coco_capture_utils::safe_delete delete_DboPagePortsIter $ports_iter
        }
        ::coco_capture_utils::safe_delete delete_DboSchematicPagesIter $pages_iter
    }
    ::coco_capture_utils::safe_delete delete_DboLibViewsIter $schem_iter

    set sorted [lsort -command ::list_ports::_cmp $records]
    set port_objs {}
    foreach rec $sorted {
        lassign $rec name x y page_path
        lappend port_objs [::coco_capture_utils::json_object_from_pairs [list \
            [::coco_capture_utils::json_field_string name $name] \
            [::coco_capture_utils::json_field_string page_path $page_path] \
            [::coco_capture_utils::json_field_number x $x] \
            [::coco_capture_utils::json_field_number y $y]]]
    }

    set pairs [list \
        [::coco_capture_utils::json_field_string command "list_ports"] \
        [::coco_capture_utils::json_field_string scope $scope] \
        [::coco_capture_utils::json_field_number pages_scanned $pages] \
        [::coco_capture_utils::json_field_number port_count [llength $port_objs]] \
        [::coco_capture_utils::json_field_json ports \
            [::coco_capture_utils::json_array_from_values $port_objs]]]
    if {$units_per_inch ne ""} {
        lappend pairs [::coco_capture_utils::json_field_number units_per_inch $units_per_inch]
    }
    if {$is_metric ne ""} {
        lappend pairs [::coco_capture_utils::json_field_bool is_metric $is_metric]
    }
    return [::coco_capture_utils::json_success [::coco_capture_utils::json_object_from_pairs $pairs]]
}

# Impl entry: arg = scope (active_page default | all)
proc ::coco_capture_list_ports_impl {arg} {
    set scope [string trim [lindex [split $arg "|"] 0]]
    if {$scope eq ""} { set scope "active_page" }
    return [::list_ports::list_ports $scope]
}
