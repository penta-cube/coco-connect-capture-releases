# coco-connect-capture find/replace bridge implementation.
#
# Increment 1 (read-only): find query text among part instances on the active
# schematic page. Searches each part's reference designator and the values of
# its effective properties, using a case-insensitive substring match.
#
# find_replace (increment 2+) adds mutation; later increments broaden object-type
# coverage: ports/off-page/globals (increment 3) and comment graphic text
# (increment 4). Remaining types (e.g. wire aliases) follow once their DBO
# iterators are verified against a live Capture session.

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

# ---------------------------------------------------------------------------
# find_replace (write, increment 2)
#
# Finds query text in the *displayed* text (DboDisplayProp) of part instances on
# the active page and replaces it. Unlike find_text (which reads every effective
# property), this targets only what is actually shown on the schematic.
#
# mode: "dry_run" (default) returns the planned changes without mutating;
#       "apply" performs the replacement (SetValueString + MarkModified).
# ---------------------------------------------------------------------------

# Read a display prop's actual displayed text (owner-arg convention, with fallback).
proc ::find_replace::_disp_text {dp} {
    set owner ""
    catch {set owner [$dp GetParentObj]}
    if {$owner ne "" && ![::coco_capture_utils::is_null $owner]} {
        if {[catch {set c [DboTclHelper_sMakeCString]}]} { return "" }
        if {![catch {$dp GetActualValueString $owner $c}]} {
            return [DboTclHelper_sGetConstCharPtr $c]
        }
    }
    if {[catch {set c2 [DboTclHelper_sMakeCString]}]} { return "" }
    if {![catch {$dp GetValueString $c2}]} {
        return [DboTclHelper_sGetConstCharPtr $c2]
    }
    return ""
}

# Display prop name (e.g. "Value", "Part Reference").
proc ::find_replace::_disp_name {dp} {
    if {[catch {set c [DboTclHelper_sMakeCString]}]} { return "" }
    if {![catch {$dp GetName $c}]} {
        return [string trim [DboTclHelper_sGetConstCharPtr $c]]
    }
    return ""
}

# Case-insensitive substring replace (replacement inserted verbatim).
proc ::find_replace::_replace_ci {text query replacement} {
    set out ""
    set lt [string tolower $text]
    set lq [string tolower $query]
    set qlen [string length $query]
    set idx 0
    while {1} {
        set found [string first $lq $lt $idx]
        if {$found < 0} {
            append out [string range $text $idx end]
            break
        }
        append out [string range $text $idx [expr {$found - 1}]] $replacement
        set idx [expr {$found + $qlen}]
    }
    return $out
}

proc ::find_replace::_change_obj {object_type refdes field old new page_path} {
    return [::coco_capture_utils::json_object_from_pairs [list \
        [::coco_capture_utils::json_field_string object_type $object_type] \
        [::coco_capture_utils::json_field_string refdes $refdes] \
        [::coco_capture_utils::json_field_string field $field] \
        [::coco_capture_utils::json_field_string old $old] \
        [::coco_capture_utils::json_field_string new $new] \
        [::coco_capture_utils::json_field_string page_path $page_path]]]
}

# Shared match/replace decision. Returns {matched newtext}.
proc ::find_replace::_eval {text query replacement match_mode} {
    if {$match_mode eq "whole"} {
        if {[string equal -nocase $text $query]} { return [list 1 $replacement] }
        return [list 0 ""]
    }
    if {[_contains $text $query]} { return [list 1 [_replace_ci $text $query $replacement]] }
    return [list 0 ""]
}

# Object name via GetName (port / offpage / global).
proc ::find_replace::_get_name {obj} {
    if {[catch {set c [DboTclHelper_sMakeCString]}]} { return "" }
    if {[catch {$obj GetName $c}]} { return "" }
    return [string trim [DboTclHelper_sGetConstCharPtr $c]]
}

# Part display prop: match+replace via GetActualValueString/SetValueString.
proc ::find_replace::_try_disp {refdes dp query replacement match_mode apply page_path changes_var} {
    upvar 1 $changes_var changes
    set text [_disp_text $dp]
    lassign [_eval $text $query $replacement $match_mode] matched newtext
    if {!$matched} { return }
    if {$apply} {
        catch {set nc [DboTclHelper_sMakeCString $newtext]}
        catch {$dp SetValueString $nc}
        catch {$dp MarkModified}
        catch {$dp SetBoundingBoxDirty 1}
    }
    lappend changes [_change_obj "part" $refdes [_disp_name $dp] $text $newtext $page_path]
}

# Name-based object (port / offpage / global): match+replace via GetName/SetName.
proc ::find_replace::_try_named {object_type obj query replacement match_mode apply page_path changes_var} {
    upvar 1 $changes_var changes
    set text [_get_name $obj]
    if {$text eq ""} { return }
    lassign [_eval $text $query $replacement $match_mode] matched newtext
    if {!$matched} { return }
    if {$apply} {
        catch {set nc [DboTclHelper_sMakeCString $newtext]}
        catch {$obj SetName $nc}
        catch {$obj MarkModified}
        catch {$obj SetBoundingBoxDirty 1}
    }
    lappend changes [_change_obj $object_type "" "name" $text $newtext $page_path]
}

# Iterate a name-based collection on a page and try replace on each.
proc ::find_replace::_scan_named {object_type page status new_method next_method \
        query replacement match_mode apply page_path scanned_var changes_var} {
    upvar 1 $scanned_var scanned
    upvar 1 $changes_var changes
    if {[catch {set it [$page $new_method $status]}]} { return }
    while {1} {
        if {[catch {set obj [$it $next_method $status]}]} { break }
        if {$obj eq "NULL"} { break }
        incr scanned
        _try_named $object_type $obj $query $replacement $match_mode $apply $page_path changes
    }
}

# Comment graphic text: match+replace via the comment-text getter chain. Unlike
# named objects, the displayed string lives on the DboCommentText definition
# (not GetName), reached through DboGraphicInstanceToDboGraphicCommentTextInst ->
# GetDboCommentText -> GetText/SetText. Free-form text is preserved verbatim
# (not trimmed) so surrounding whitespace survives a substring replace.
proc ::find_replace::_try_comment {obj query replacement match_mode apply page_path changes_var} {
    upvar 1 $changes_var changes
    if {[catch {set textInst [DboGraphicInstanceToDboGraphicCommentTextInst $obj]}]} { return }
    if {[::coco_capture_utils::is_null $textInst]} { return }
    if {[catch {set textDef [$textInst GetDboCommentText]}]} { return }
    if {[::coco_capture_utils::is_null $textDef]} { return }
    if {[catch {set c [DboTclHelper_sMakeCString]}]} { return }
    if {[catch {$textDef GetText $c}]} { return }
    set text [DboTclHelper_sGetConstCharPtr $c]
    if {$text eq ""} { return }
    lassign [_eval $text $query $replacement $match_mode] matched newtext
    if {!$matched} { return }
    if {$apply} {
        catch {set nc [DboTclHelper_sMakeCString $newtext]}
        catch {$textDef SetText $nc}
        catch {$textDef SetRecalBoundingBox}
        catch {$textInst MarkModified}
    }
    lappend changes [_change_obj "comment" "" "text" $text $newtext $page_path]
}

# Iterate comment graphics on a page and try replace on each.
proc ::find_replace::_scan_comment {page status query replacement match_mode apply \
        page_path scanned_var changes_var} {
    upvar 1 $scanned_var scanned
    upvar 1 $changes_var changes
    if {[catch {set it [$page NewCommentGraphicsIter $status]}]} { return }
    while {1} {
        if {[catch {set obj [$it NextCommentGraphic $status]}]} { break }
        if {$obj eq "NULL"} { break }
        incr scanned
        _try_comment $obj $query $replacement $match_mode $apply $page_path changes
    }
    ::coco_capture_utils::safe_delete delete_DboPageCommentGraphicsIter $it
}

# find_replace (increment 4): find/replace text across object types
#   - part      -> displayed text (DboDisplayProp)
#   - port / offpage / global -> object name (GetName/SetName)
#   - comment   -> comment graphic text (GetDboCommentText/GetText/SetText)
# scope: active_page (default) | all (every page in the design)
proc ::find_replace::find_replace {query replacement mode match_mode scope} {
    set query [string trim $query]
    if {$query eq ""} {
        error [::coco_capture_utils::json_error "invalid_arg" "query is required" \
            [::coco_capture_utils::json_object_from_pairs [list \
                [::coco_capture_utils::json_field_string command "find_replace"]]]]
    }
    set apply [expr {$mode eq "apply"}]
    if {$match_mode ne "whole"} { set match_mode "substring" }
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

    set changes {}
    set scanned 0
    set pages 0

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

            # 1. parts -> display props
            if {![catch {set part_iter [$page NewPartInstsIter $status]}]} {
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
                    if {[catch {set dp_iter [$placed_inst NewDisplayPropsIter $status]}]} { continue }
                    while {1} {
                        if {[catch {set dp [$dp_iter NextProp $status]}]} { break }
                        if {$dp eq $null_obj} { break }
                        _try_disp $refdes $dp $query $replacement $match_mode $apply $page_path changes
                    }
                    ::coco_capture_utils::safe_delete delete_DboDisplayPropsIter $dp_iter
                }
                ::coco_capture_utils::safe_delete delete_DboPagePartInstsIter $part_iter
            }

            # 2. ports / offpage / globals (name-based)
            _scan_named port $page $status NewPortsIter NextPort \
                $query $replacement $match_mode $apply $page_path scanned changes
            _scan_named offpage $page $status NewOffPageConnectorsIter NextOffPageConnector \
                $query $replacement $match_mode $apply $page_path scanned changes
            _scan_named global $page $status NewGlobalsIter NextGlobal \
                $query $replacement $match_mode $apply $page_path scanned changes

            # 3. comment graphic text (free text, getter-chain based)
            _scan_comment $page $status \
                $query $replacement $match_mode $apply $page_path scanned changes
        }
        ::coco_capture_utils::safe_delete delete_DboSchematicPagesIter $pages_iter
    }
    ::coco_capture_utils::safe_delete delete_DboLibViewsIter $schem_iter

    set data [::coco_capture_utils::json_object_from_pairs [list \
        [::coco_capture_utils::json_field_string command "find_replace"] \
        [::coco_capture_utils::json_field_string mode [expr {$apply ? "apply" : "dry_run"}]] \
        [::coco_capture_utils::json_field_string scope $scope] \
        [::coco_capture_utils::json_field_string query $query] \
        [::coco_capture_utils::json_field_string replacement $replacement] \
        [::coco_capture_utils::json_field_string match_mode $match_mode] \
        [::coco_capture_utils::json_field_number pages_scanned $pages] \
        [::coco_capture_utils::json_field_number scanned_objects $scanned] \
        [::coco_capture_utils::json_field_number match_count [llength $changes]] \
        [::coco_capture_utils::json_field_json changes \
            [::coco_capture_utils::json_array_from_values $changes]]]]
    return [::coco_capture_utils::json_success $data]
}

# Impl entry: arg = query|replacement|mode|match_mode|scope
#   mode: dry_run (default) | apply
#   match_mode: substring (default) | whole
#   scope: active_page (default) | all
proc ::coco_capture_find_replace_impl {arg} {
    set parts [split $arg "|"]
    set query [lindex $parts 0]
    set replacement [lindex $parts 1]
    set mode [lindex $parts 2]
    set match_mode [lindex $parts 3]
    set scope [lindex $parts 4]
    if {$mode eq ""} { set mode "dry_run" }
    if {$match_mode eq ""} { set match_mode "substring" }
    if {$scope eq ""} { set scope "active_page" }
    return [::find_replace::find_replace $query $replacement $mode $match_mode $scope]
}
