# coco-connect-capture get_text_objects bridge implementation (M2).
#
# Enumerates free-standing comment/annotation text on schematic pages with their
# text content + coordinates, sorted by (x, y). JSON replacement for the
# benchmark's copy_text.tcl / copy_xy_text.tcl ("Copy XY / Text"). Read-only.
#
# Unlike list_ports (which reads an object NAME via GetName), comment text lives
# on a separate DboCommentText definition reached through the getter chain
# (DboGraphicInstanceToDboGraphicCommentTextInst -> GetDboCommentText -> GetText)
# -- the same path find_replace's comment support uses. NewCommentGraphicsIter
# also yields non-text comment graphics (lines/boxes); those cast to NULL and are
# skipped. Reuses the shared geometry/sort/page helpers in list_ports.tcl
# (::list_objects::). scope: active_page (default) | all.

namespace eval ::get_text_objects {
}

# Visible text of a comment graphic instance via the getter chain. Returns "" for
# non-text comment graphics (the cast yields NULL) so the caller skips them.
proc ::get_text_objects::_comment_text {obj} {
    if {[catch {set textInst [DboGraphicInstanceToDboGraphicCommentTextInst $obj]}]} { return "" }
    if {[::coco_capture_utils::is_null $textInst]} { return "" }
    if {[catch {set textDef [$textInst GetDboCommentText]}]} { return "" }
    if {[::coco_capture_utils::is_null $textDef]} { return "" }
    if {[catch {set c [DboTclHelper_sMakeCString]}]} { return "" }
    if {[catch {$textDef GetText $c}]} { return "" }
    if {[catch {set v [DboTclHelper_sGetConstCharPtr $c]}]} { return "" }
    return $v
}

# Core: enumerate comment text across the requested scope, sorted by (x, y).
proc ::get_text_objects::get_text_objects {scope} {
    if {$scope ne "all"} { set scope "active_page" }

    set status [::coco_capture_utils::status]
    set session [::coco_capture_utils::session]
    set design [::coco_capture_utils::active_design $session $status]
    set null_obj "NULL"

    set active_page_name ""
    if {$scope eq "active_page"} {
        set active_page_name [::list_objects::_active_page_name]
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
            ::list_objects::_read_units $page units_per_inch is_metric

            if {[catch {set it [$page NewCommentGraphicsIter $status]}]} { continue }
            while {1} {
                if {[catch {set obj [$it NextCommentGraphic $status]}]} { break }
                if {$obj eq $null_obj} { break }
                set text [_comment_text $obj]
                if {$text eq ""} { continue }
                lassign [::list_objects::_abs_coords $obj $status] x y
                lappend records [list $text $x $y $page_path]
            }
            ::coco_capture_utils::safe_delete delete_DboPageCommentGraphicsIter $it
        }
        ::coco_capture_utils::safe_delete delete_DboSchematicPagesIter $pages_iter
    }
    ::coco_capture_utils::safe_delete delete_DboLibViewsIter $schem_iter

    set sorted [lsort -command ::list_objects::_cmp $records]
    set objs {}
    foreach rec $sorted {
        lassign $rec text x y page_path
        lappend objs [::coco_capture_utils::json_object_from_pairs [list \
            [::coco_capture_utils::json_field_string text $text] \
            [::coco_capture_utils::json_field_string page_path $page_path] \
            [::coco_capture_utils::json_field_number x $x] \
            [::coco_capture_utils::json_field_number y $y]]]
    }

    set pairs [list \
        [::coco_capture_utils::json_field_string command "get_text_objects"] \
        [::coco_capture_utils::json_field_string scope $scope] \
        [::coco_capture_utils::json_field_number pages_scanned $pages] \
        [::coco_capture_utils::json_field_number text_object_count [llength $objs]] \
        [::coco_capture_utils::json_field_json text_objects \
            [::coco_capture_utils::json_array_from_values $objs]]]
    if {$units_per_inch ne ""} {
        lappend pairs [::coco_capture_utils::json_field_number units_per_inch $units_per_inch]
    }
    if {$is_metric ne ""} {
        lappend pairs [::coco_capture_utils::json_field_bool is_metric $is_metric]
    }
    return [::coco_capture_utils::json_success [::coco_capture_utils::json_object_from_pairs $pairs]]
}

# Impl entry: arg = scope (active_page default | all)
proc ::coco_capture_get_text_objects_impl {arg} {
    set scope [string trim [lindex [split $arg "|"] 0]]
    if {$scope eq ""} { set scope "active_page" }
    return [::get_text_objects::get_text_objects $scope]
}
