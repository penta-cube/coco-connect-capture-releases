# coco-connect-capture find/replace bridge implementation.
#
# Increment 1 (read-only): find query text among part instances on the active
# schematic page. Searches each part's reference designator and the values of
# its effective properties, using a case-insensitive substring match.
#
# Replace (mutation) is intentionally NOT implemented yet; see the feature plan.
# Object-type coverage beyond part instances (ports, off-page connectors,
# comment text, wire aliases) is added in a later increment once the matching
# DBO iterators are verified against a live Capture session.

namespace eval ::find_replace {
}

# Case-insensitive substring match.
proc ::find_replace::_contains {haystack needle} {
    if {$needle eq ""} {
        return 0
    }
    return [expr {[string first [string tolower $needle] [string tolower $haystack]] >= 0}]
}

# Resolve the active page name, if Capture exposes GetActivePage. Returns "" when
# no active page can be determined (caller then scans every page).
proc ::find_replace::_active_page_name {} {
    if {![::coco_capture_utils::cmd_exists GetActivePage]} {
        return ""
    }
    if {[catch {set page [GetActivePage]}]} {
        return ""
    }
    if {[::coco_capture_utils::is_null $page]} {
        return ""
    }
    return [::coco_capture_utils::name $page]
}

# Build one match object for the JSON `matches` array.
proc ::find_replace::_match_obj {refdes field text page_path} {
    return [::coco_capture_utils::json_object_from_pairs [list \
        [::coco_capture_utils::json_field_string refdes $refdes] \
        [::coco_capture_utils::json_field_string field $field] \
        [::coco_capture_utils::json_field_string text $text] \
        [::coco_capture_utils::json_field_string page_path $page_path]]]
}

# Core: scan part instances and collect matches.
proc ::find_replace::find_text {query} {
    set query [string trim $query]
    if {$query eq ""} {
        error [::coco_capture_utils::json_error "invalid_arg" "query is required" \
            [::coco_capture_utils::json_object_from_pairs [list \
                [::coco_capture_utils::json_field_string command "find_text"]]]]
    }

    set status [::coco_capture_utils::status]
    set session [::coco_capture_utils::session]
    set design [::coco_capture_utils::active_design $session $status]
    set null_obj "NULL"

    set active_page_name [_active_page_name]
    if {$active_page_name eq ""} {
        set scope "all_pages"
    } else {
        set scope "active_page"
    }

    set matches {}
    set scanned 0
    set scanned_page_path ""

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

            # Active-page filter (by name; robust to handle differences).
            if {$active_page_name ne "" && ![string equal $page_name $active_page_name]} {
                continue
            }

            set page_path [::coco_capture_utils::page_path $schematic_name $page_name]
            set scanned_page_path $page_path

            if {[catch {set part_iter [$page NewPartInstsIter $status]}]} { continue }
            while {1} {
                if {[catch {set inst [$part_iter NextPartInst $status]}]} { break }
                if {$inst eq $null_obj} { break }

                set placed_inst $inst
                if {[::coco_capture_utils::cmd_exists DboPartInstToDboPlacedInst]} {
                    set placed_inst [DboPartInstToDboPlacedInst $inst]
                }
                if {[::coco_capture_utils::is_null $placed_inst]} { continue }

                incr scanned
                set refdes [::coco_capture_utils::refdes $placed_inst]

                if {[_contains $refdes $query]} {
                    lappend matches [_match_obj $refdes "refdes" $refdes $page_path]
                }

                if {[catch {set props [::property::_collect_effective_props $placed_inst]} err]} {
                    set props [dict create]
                }
                dict for {pname pval} $props {
                    if {[_contains $pval $query]} {
                        lappend matches [_match_obj $refdes $pname $pval $page_path]
                    }
                }
            }
            ::coco_capture_utils::safe_delete delete_DboPagePartInstsIter $part_iter
        }
        ::coco_capture_utils::safe_delete delete_DboSchematicPagesIter $pages_iter
    }
    ::coco_capture_utils::safe_delete delete_DboLibViewsIter $schem_iter

    set data [::coco_capture_utils::json_object_from_pairs [list \
        [::coco_capture_utils::json_field_string command "find_text"] \
        [::coco_capture_utils::json_field_string scope $scope] \
        [::coco_capture_utils::json_field_string page_path $scanned_page_path] \
        [::coco_capture_utils::json_field_string query $query] \
        [::coco_capture_utils::json_field_number scanned_parts $scanned] \
        [::coco_capture_utils::json_field_number match_count [llength $matches]] \
        [::coco_capture_utils::json_field_json matches \
            [::coco_capture_utils::json_array_from_values $matches]]]]
    return [::coco_capture_utils::json_success $data]
}

# Impl entry point invoked by the bootstrap wrapper.
proc ::coco_capture_find_text_impl {query} {
    return [::find_replace::find_text $query]
}
