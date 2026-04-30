namespace eval ::highlight {
    variable _last_result [dict create status "idle" reason "" selected 0 pages 0]
}

# Usage:
#   source utils.tcl
#   source highlight.tcl
#   highlight_part U12
#   highlight_net CLK

proc ::highlight::_set_result {status reason selected pages} {
    variable _last_result
    set _last_result [dict create \
        status $status \
        reason $reason \
        selected $selected \
        pages $pages]
}

proc ::highlight::last_result {} {
    variable _last_result
    return $_last_result
}

proc ::highlight::_is_view_active {} {
    if {[::coco_capture_utils::cmd_exists IsSchematicViewActive]} {
        if {![catch {set active [IsSchematicViewActive]}]} {
            return [expr {$active ? 1 : 0}]
        }
    }
    if {[::coco_capture_utils::cmd_exists GetActivePage]} {
        if {![catch {set page [GetActivePage]}] && ![::coco_capture_utils::is_null $page]} {
            return 1
        }
    }
    return 0
}

proc ::highlight::_activate_page {page_path {schematic_name ""} {page_name ""} {design_name ""}} {
    if {$design_name ne "" && [::coco_capture_utils::cmd_exists SelectPMItem]} {
        catch {SelectPMItem "./$design_name"}
        catch {SelectPMItem $design_name}
    }

    if {$schematic_name ne "" && [::coco_capture_utils::cmd_exists SelectPMItem]} {
        catch {SelectPMItem $schematic_name}
    }

    if {$schematic_name ne "" && $page_name ne "" && [::coco_capture_utils::cmd_exists OPage]} {
        catch {OPage $schematic_name $page_name}
        catch {update idletasks}
        if {[_is_view_active]} {
            return 1
        }
    }

    if {$schematic_name ne "" && $page_name ne "" && [::coco_capture_utils::cmd_exists NPage]} {
        if {![catch {NPage $schematic_name $page_name}]} {
            if {[::coco_capture_utils::cmd_exists OPage]} {
                catch {OPage $schematic_name $page_name}
            }
            catch {update idletasks}
            if {[_is_view_active]} {
                return 1
            }
        }
    }

    if {![::coco_capture_utils::cmd_exists SelectPMItem]} {
        return [_is_view_active]
    }

    foreach candidate [list $page_path "./$page_path"] {
        if {$candidate eq "" || [catch {SelectPMItem $candidate}]} {
            continue
        }
        foreach open_cmd {OpenPMItem ActivatePMItem OpenPage OpenSchematicPage} {
            if {[::coco_capture_utils::cmd_exists $open_cmd]} {
                catch {$open_cmd $candidate}
                catch {$open_cmd}
            }
        }
        if {[::coco_capture_utils::cmd_exists Menu]} {
            catch {Menu "Edit::Browse"}
        }
        catch {update idletasks}
        if {[_is_view_active]} {
            return 1
        }
    }
    return 0
}

proc ::highlight::_clear {} {
    foreach cmd_name {UnSelectAll UnselectAll ClearSelection} {
        if {[::coco_capture_utils::cmd_exists $cmd_name] && ![catch [list $cmd_name]]} {
            return 1
        }
    }

    if {[::coco_capture_utils::cmd_exists Menu]} {
        foreach menu_cmd {
            {Edit::Unselect All}
            {Edit::UnSelect All}
            {Edit::Clear Selection}
        } {
            if {![catch [list Menu $menu_cmd]]} {
                return 1
            }
        }
    }
    return 0
}

proc ::highlight::_select_part_on_active_page {refdes} {
    if {![::coco_capture_utils::cmd_exists GetActivePage] || ![::coco_capture_utils::cmd_exists SelectObjectById]} {
        error "GetActivePage/SelectObjectById command is not available"
    }

    set status [::coco_capture_utils::status]
    set page [GetActivePage]
    if {$page eq "" || [::coco_capture_utils::is_null $page]} {
        error "active page is not available"
    }

    set selected 0
    set seen [dict create]
    set null_obj "NULL"

    if {[catch {set part_iter [$page NewPartInstsIter $status]}]} {
        error "active page part iterator is not available"
    }

    while {1} {
        if {[catch {set inst [$part_iter NextPartInst $status]}]} {
            break
        }
        if {$inst eq $null_obj} {
            break
        }

        set placed_inst $inst
        if {[::coco_capture_utils::cmd_exists DboPartInstToDboPlacedInst]} {
            set placed_inst [DboPartInstToDboPlacedInst $inst]
        }
        if {[::coco_capture_utils::is_null $placed_inst]} {
            continue
        }

        if {![string equal -nocase [::coco_capture_utils::refdes $placed_inst] $refdes]} {
            continue
        }

        set object_id [::coco_capture_utils::id $placed_inst $status]
        if {$object_id eq "" || [dict exists $seen $object_id]} {
            continue
        }

        dict set seen $object_id 1
        if {![catch {SelectObjectById $object_id}]} {
            incr selected
        }
    }

    ::coco_capture_utils::safe_delete delete_DboPagePartInstsIter $part_iter
    return $selected
}

proc ::highlight::_select_net_on_active_page {net_name} {
    if {![::coco_capture_utils::cmd_exists GetActivePage] || ![::coco_capture_utils::cmd_exists SelectObjectById]} {
        error "GetActivePage/SelectObjectById command is not available"
    }

    set status [::coco_capture_utils::status]
    set page [GetActivePage]
    if {$page eq "" || [::coco_capture_utils::is_null $page]} {
        error "active page is not available"
    }

    set selected 0
    set wire_list {}
    set null_obj "NULL"

    set net_obj ""
    if {[::coco_capture_utils::cmd_exists DboTclHelper_sMakeCString]} {
        if {![catch {set cnet [DboTclHelper_sMakeCString $net_name]}]} {
            catch {set net_obj [$page GetNet $cnet $status]}
        }
    }
    if {$net_obj eq "" || [::coco_capture_utils::is_null $net_obj]} {
        catch {set net_obj [$page GetNet $net_name $status]}
    }

    if {$net_obj ne "" && ![::coco_capture_utils::is_null $net_obj]} {
        if {[::coco_capture_utils::cmd_exists DboNetWiresIter] && [info exists ::IterDefs_ALL]} {
            set iter_cmd "hlNetWiresIter_[clock clicks]"
            if {![catch {DboNetWiresIter $iter_cmd $net_obj $::IterDefs_ALL}]} {
                while {1} {
                    if {[catch {set wire [$iter_cmd NextWire $status]}]} {
                        break
                    }
                    if {$wire eq $null_obj} {
                        break
                    }
                    lappend wire_list $wire
                }
                catch {rename $iter_cmd ""}
            }
        }

        if {[llength $wire_list] == 0 && [catch {set wires_iter [$net_obj NewWiresIter $status]}] == 0} {
            while {1} {
                if {[catch {set wire [$wires_iter NextWire $status]}]} {
                    break
                }
                if {$wire eq $null_obj} {
                    break
                }
                lappend wire_list $wire
            }
            ::coco_capture_utils::safe_delete delete_DboNetWiresIter $wires_iter
            ::coco_capture_utils::safe_delete delete_DboPageWiresIter $wires_iter
        }

        if {[llength $wire_list] == 0} {
            set net_id [::coco_capture_utils::id $net_obj $status]
            if {$net_id ne "" && ![catch {SelectObjectById $net_id}]} {
                incr selected
            }
        }
    }

    foreach wire $wire_list {
        set object_id [::coco_capture_utils::id $wire $status]
        if {$object_id eq ""} {
            continue
        }
        if {![catch {SelectObjectById $object_id}]} {
            incr selected
        }
    }

    return $selected
}

proc ::highlight::_find_part_pages {session refdes} {
    set status [::coco_capture_utils::status]
    set design [::coco_capture_utils::active_design $session $status]
    set design_name [::coco_capture_utils::name $design]
    set matches {}
    set seen [dict create]
    set null_obj "NULL"

    set schem_iter [::coco_capture_utils::schem_iter $design $status]
    while {1} {
        if {[catch {set view [$schem_iter NextView $status]}]} {
            break
        }
        if {$view eq $null_obj} {
            break
        }

        set schematic [::coco_capture_utils::to_schematic $view]
        set schematic_name [::coco_capture_utils::name $schematic]

        if {[catch {set pages_iter [$schematic NewPagesIter $status]}]} {
            continue
        }

        while {1} {
            if {[catch {set page [$pages_iter NextPage $status]}]} {
                break
            }
            if {$page eq $null_obj} {
                break
            }

            set page_id [::coco_capture_utils::id $page $status]
            set page_name [::coco_capture_utils::name $page]
            set page_path [::coco_capture_utils::page_path $schematic_name $page_name]

            set found 0
            if {![catch {set part_iter [$page NewPartInstsIter $status]}]} {
                while {1} {
                    if {[catch {set inst [$part_iter NextPartInst $status]}]} {
                        break
                    }
                    if {$inst eq $null_obj} {
                        break
                    }
                    set placed_inst $inst
                    if {[::coco_capture_utils::cmd_exists DboPartInstToDboPlacedInst]} {
                        set placed_inst [DboPartInstToDboPlacedInst $inst]
                    }
                    if {[::coco_capture_utils::is_null $placed_inst]} {
                        continue
                    }
                    if {[string equal -nocase [::coco_capture_utils::refdes $placed_inst] $refdes]} {
                        set found 1
                        break
                    }
                }
                ::coco_capture_utils::safe_delete delete_DboPagePartInstsIter $part_iter
            }

            if {!$found} {
                continue
            }

            set page_key $page_path
            if {$page_key eq ""} {
                set page_key $page_id
            }
            if {$page_key eq "" || [dict exists $seen $page_key]} {
                continue
            }
            dict set seen $page_key 1

            lappend matches [dict create \
                page_id $page_id \
                page_path $page_path \
                page_name $page_name \
                schematic_name $schematic_name \
                design_name $design_name]
        }

        ::coco_capture_utils::safe_delete delete_DboSchematicPagesIter $pages_iter
    }

    ::coco_capture_utils::safe_delete delete_DboLibViewsIter $schem_iter
    return $matches
}

proc ::highlight::_find_net_pages {session net_name} {
    set status [::coco_capture_utils::status]
    set design [::coco_capture_utils::active_design $session $status]
    set design_name [::coco_capture_utils::name $design]
    set matches {}
    set seen [dict create]
    set null_obj "NULL"

    set schem_iter [::coco_capture_utils::schem_iter $design $status]
    while {1} {
        if {[catch {set view [$schem_iter NextView $status]}]} {
            break
        }
        if {$view eq $null_obj} {
            break
        }

        set schematic [::coco_capture_utils::to_schematic $view]
        set schematic_name [::coco_capture_utils::name $schematic]

        if {[catch {set pages_iter [$schematic NewPagesIter $status]}]} {
            continue
        }

        while {1} {
            if {[catch {set page [$pages_iter NextPage $status]}]} {
                break
            }
            if {$page eq $null_obj} {
                break
            }

            set net_obj ""
            if {[::coco_capture_utils::cmd_exists DboTclHelper_sMakeCString]} {
                if {![catch {set cnet [DboTclHelper_sMakeCString $net_name]}]} {
                    catch {set net_obj [$page GetNet $cnet $status]}
                }
            }
            if {$net_obj eq "" || [::coco_capture_utils::is_null $net_obj]} {
                catch {set net_obj [$page GetNet $net_name $status]}
            }
            if {$net_obj eq "" || [::coco_capture_utils::is_null $net_obj]} {
                continue
            }

            set page_id [::coco_capture_utils::id $page $status]
            set page_name [::coco_capture_utils::name $page]
            set page_path [::coco_capture_utils::page_path $schematic_name $page_name]

            set page_key $page_path
            if {$page_key eq ""} {
                set page_key $page_id
            }
            if {$page_key eq "" || [dict exists $seen $page_key]} {
                continue
            }
            dict set seen $page_key 1

            lappend matches [dict create \
                page_id $page_id \
                page_path $page_path \
                page_name $page_name \
                schematic_name $schematic_name \
                design_name $design_name]
        }

        ::coco_capture_utils::safe_delete delete_DboSchematicPagesIter $pages_iter
    }

    ::coco_capture_utils::safe_delete delete_DboLibViewsIter $schem_iter
    return $matches
}

proc ::highlight::_activate_match_page {page} {
    set page_path [dict get $page page_path]
    set schematic_name [dict get $page schematic_name]
    set page_name [dict get $page page_name]
    set design_name [dict get $page design_name]
    return [_activate_page $page_path $schematic_name $page_name $design_name]
}

proc ::highlight::_highlight_pages {pages select_proc select_arg} {
    set page_count [llength $pages]
    if {$page_count == 0} {
        _set_result "no_match" "" 0 0
        return 0
    }

    catch {_clear}

    set selected_count 0
    set first_page ""
    set activation_failures 0
    set selection_failures 0

    foreach page $pages {
        if {[catch {set activated [_activate_match_page $page]}]} {
            incr activation_failures
            continue
        }
        if {!$activated} {
            incr activation_failures
            continue
        }

        if {$first_page eq ""} {
            set first_page $page
        }

        if {[catch {set page_selected [uplevel #0 [list $select_proc $select_arg]]}]} {
            incr selection_failures
            continue
        }
        incr selected_count $page_selected
    }

    if {$first_page ne ""} {
        catch {_activate_match_page $first_page}
    }

    if {$selected_count > 0} {
        _set_result "ok" "" $selected_count $page_count
    } elseif {$selection_failures > 0 || $activation_failures > 0} {
        _set_result "error" "selection_failed" 0 $page_count
    } else {
        _set_result "no_match" "" 0 $page_count
    }

    return $selected_count
}

proc ::highlight::_run_highlight {query invalid_reason find_proc select_proc} {
    set query [string trim $query]
    if {$query eq ""} {
        _set_result "invalid_arg" $invalid_reason 0 0
        return 0
    }

    if {[catch {set session [::coco_capture_utils::session]} err]} {
        _set_result "error" "session_error: $err" 0 0
        return 0
    }

    if {[catch {set pages [uplevel #0 [list $find_proc $session $query]]} err]} {
        _set_result "error" "search_error: $err" 0 0
        return 0
    }

    return [_highlight_pages $pages $select_proc $query]
}

proc ::highlight::part {refdes} {
    return [_run_highlight \
        $refdes \
        "empty_refdes" \
        ::highlight::_find_part_pages \
        ::highlight::_select_part_on_active_page]
}

proc ::highlight::net {net_name} {
    return [_run_highlight \
        $net_name \
        "empty_net_name" \
        ::highlight::_find_net_pages \
        ::highlight::_select_net_on_active_page]
}

proc ::highlight::clear {} {
    if {[_clear]} {
        _set_result "ok" "" 0 0
        return 1
    }
    _set_result "error" "selection clear command is not available (expected: UnSelectAll)" 0 0
    return 0
}

proc ::highlight::_part_response {refdes} {
    set result [last_result]
    set status [dict get $result status]
    set reason [dict get $result reason]
    set selected [dict get $result selected]
    set pages [dict get $result pages]

    switch -- $status {
        ok {
            return [::coco_capture_utils::json_success \
                [::coco_capture_utils::json_object_from_pairs [list \
                    [::coco_capture_utils::json_field_string command "highlight_part"] \
                    [::coco_capture_utils::json_field_string refdes $refdes] \
                    [::coco_capture_utils::json_field_number pages $pages] \
                    [::coco_capture_utils::json_field_number selected $selected]]]]
        }
        no_match {
            error [::coco_capture_utils::json_error \
                "no_match" \
                "No matching part found" \
                [::coco_capture_utils::json_object_from_pairs [list \
                    [::coco_capture_utils::json_field_string command "highlight_part"] \
                    [::coco_capture_utils::json_field_string refdes $refdes]]]]
        }
        invalid_arg {
            error [::coco_capture_utils::json_error \
                "invalid_arg" \
                "part is required" \
                [::coco_capture_utils::json_object_from_pairs [list \
                    [::coco_capture_utils::json_field_string command "highlight_part"]]]]
        }
        error {
            set message "part highlight failed"
            if {$reason ne ""} {
                set message $reason
            }
            error [::coco_capture_utils::json_error \
                "highlight_failed" \
                $message \
                [::coco_capture_utils::json_object_from_pairs [list \
                    [::coco_capture_utils::json_field_string command "highlight_part"] \
                    [::coco_capture_utils::json_field_string refdes $refdes]]]]
        }
        default {
            error [::coco_capture_utils::json_error \
                "highlight_failed" \
                "part highlight failed: $status" \
                [::coco_capture_utils::json_object_from_pairs [list \
                    [::coco_capture_utils::json_field_string command "highlight_part"] \
                    [::coco_capture_utils::json_field_string refdes $refdes] \
                    [::coco_capture_utils::json_field_string status $status]]]]
        }
    }
}

proc ::highlight::_net_response {net_name} {
    set result [last_result]
    set status [dict get $result status]
    set reason [dict get $result reason]
    set selected [dict get $result selected]
    set pages [dict get $result pages]

    switch -- $status {
        ok {
            return [::coco_capture_utils::json_success \
                [::coco_capture_utils::json_object_from_pairs [list \
                    [::coco_capture_utils::json_field_string command "highlight_net"] \
                    [::coco_capture_utils::json_field_string net $net_name] \
                    [::coco_capture_utils::json_field_number pages $pages] \
                    [::coco_capture_utils::json_field_number selected $selected]]]]
        }
        no_match {
            error [::coco_capture_utils::json_error \
                "no_match" \
                "No matching net found" \
                [::coco_capture_utils::json_object_from_pairs [list \
                    [::coco_capture_utils::json_field_string command "highlight_net"] \
                    [::coco_capture_utils::json_field_string net $net_name]]]]
        }
        invalid_arg {
            error [::coco_capture_utils::json_error \
                "invalid_arg" \
                "net is required" \
                [::coco_capture_utils::json_object_from_pairs [list \
                    [::coco_capture_utils::json_field_string command "highlight_net"]]]]
        }
        error {
            set message "net highlight failed"
            if {$reason ne ""} {
                set message $reason
            }
            error [::coco_capture_utils::json_error \
                "highlight_failed" \
                $message \
                [::coco_capture_utils::json_object_from_pairs [list \
                    [::coco_capture_utils::json_field_string command "highlight_net"] \
                    [::coco_capture_utils::json_field_string net $net_name]]]]
        }
        default {
            error [::coco_capture_utils::json_error \
                "highlight_failed" \
                "net highlight failed: $status" \
                [::coco_capture_utils::json_object_from_pairs [list \
                    [::coco_capture_utils::json_field_string command "highlight_net"] \
                    [::coco_capture_utils::json_field_string net $net_name] \
                    [::coco_capture_utils::json_field_string status $status]]]]
        }
    }
}

proc ::highlight::_clear_response {} {
    set result [last_result]
    set status [dict get $result status]
    set reason [dict get $result reason]

    if {$status eq "ok"} {
        return [::coco_capture_utils::json_success \
            [::coco_capture_utils::json_object_from_pairs [list \
                [::coco_capture_utils::json_field_string command "clear_highlight"]]]]
    }
    set message "clear highlight failed"
    if {$reason ne ""} {
        set message $reason
    }
    error [::coco_capture_utils::json_error \
        "clear_failed" \
        $message \
        [::coco_capture_utils::json_object_from_pairs [list \
            [::coco_capture_utils::json_field_string command "clear_highlight"]]]]
}

# Bridge hook functions consumed by coco_capture_bootstrap.tcl
proc ::coco_capture_highlight_part_impl {refdes} {
    ::highlight::part $refdes
    return [::highlight::_part_response $refdes]
}

proc ::coco_capture_highlight_net_impl {net_name} {
    ::highlight::net $net_name
    return [::highlight::_net_response $net_name]
}

proc ::coco_capture_clear_highlight_impl {} {
    ::highlight::clear
    return [::highlight::_clear_response]
}

# Optional direct wrappers for manual Tcl usage
proc highlight_part {refdes} {
    return [::coco_capture_highlight_part_impl $refdes]
}

proc highlight_net {net_name} {
    return [::coco_capture_highlight_net_impl $net_name]
}

proc clear_highlight {} {
    return [::coco_capture_clear_highlight_impl]
}
