namespace eval ::highlight {
    variable _last_result [dict create status "idle" reason "" selected 0 pages 0]
}

# Usage:
#   source highlight.tcl
#   highlight_part U12
#   highlight_net CLK

proc ::highlight::_cmd {name} {
    expr {[llength [info commands $name]] > 0}
}

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

proc ::highlight::_is_null {obj} {
    expr {$obj eq "" || [string equal -nocase $obj "NULL"]}
}

proc ::highlight::_status {} {
    if {[_cmd DboState]} {
        return [DboState]
    }
    return ""
}

proc ::highlight::_safe_delete {delete_proc iter_obj} {
    if {$iter_obj eq "" || [_is_null $iter_obj]} {
        return
    }
    if {[_cmd $delete_proc]} {
        catch {$delete_proc $iter_obj}
    }
}

proc ::highlight::_cstring_get {obj method} {
    if {![_cmd DboTclHelper_sMakeCString] || ![_cmd DboTclHelper_sGetConstCharPtr]} {
        return ""
    }
    if {[catch {set cstr [DboTclHelper_sMakeCString]}]} {
        return ""
    }
    if {[catch {$obj $method $cstr}]} {
        return ""
    }
    return [string trim [DboTclHelper_sGetConstCharPtr $cstr]]
}

proc ::highlight::_name {obj} {
    set v [_cstring_get $obj GetName]
    if {$v ne ""} {
        return $v
    }
    set v [_cstring_get $obj GetNetName]
    if {$v ne ""} {
        return $v
    }
    if {[catch {set v [$obj GetName]}]} {
        return ""
    }
    return [string trim $v]
}

proc ::highlight::_refdes {placed_inst} {
    set v [_cstring_get $placed_inst GetReferenceDesignator]
    if {$v ne ""} {
        return $v
    }
    return [_name $placed_inst]
}

proc ::highlight::_id {obj {status ""}} {
    if {$obj eq "" || [_is_null $obj]} {
        return ""
    }
    if {$status ne "" && ![catch {set oid [$obj GetId $status]}]} {
        return $oid
    }
    if {![catch {set oid [$obj GetId]}]} {
        return $oid
    }
    return ""
}

proc ::highlight::_page_path {schematic_name page_name} {
    if {$schematic_name eq "" && $page_name eq ""} {
        return ""
    }
    if {$schematic_name eq ""} {
        return $page_name
    }
    if {$page_name eq ""} {
        return $schematic_name
    }
    return "${schematic_name}/${page_name}"
}

proc ::highlight::_session {} {
    if {[info exists ::DboSession_s_pDboSession] && ![_is_null $::DboSession_s_pDboSession]} {
        set session $::DboSession_s_pDboSession
        catch {DboSession -this $session}
        return $session
    }
    if {[_cmd GetActivePMDesign]} {
        return "__CAPTURE_SESSION_IMPLICIT__"
    }
    error "Capture session handle is not available"
}

proc ::highlight::_active_design {session status} {
    if {[_cmd GetActivePMDesign]} {
        if {![catch {set design [GetActivePMDesign]}] && ![_is_null $design]} {
            return $design
        }
    }
    if {$session ne "" && ![_is_null $session]} {
        if {$status ne "" && ![catch {set design [$session GetActiveDesign $status]}] && ![_is_null $design]} {
            return $design
        }
        if {![catch {set design [$session GetActiveDesign]}] && ![_is_null $design]} {
            return $design
        }
    }
    error "active design not available"
}

proc ::highlight::_schem_iter {design status} {
    if {[info exists ::IterDefs_SCHEMATICS]} {
        if {![catch {set iter [$design NewViewsIter $status $::IterDefs_SCHEMATICS]}]} {
            return $iter
        }
    }
    if {![catch {set iter [$design NewViewsIter $status]}]} {
        return $iter
    }
    error "cannot create schematic views iterator"
}

proc ::highlight::_to_schematic {view_obj} {
    if {[_cmd DboViewToDboSchematic]} {
        if {![catch {set schematic [DboViewToDboSchematic $view_obj]}] && ![_is_null $schematic]} {
            return $schematic
        }
    }
    return $view_obj
}

proc ::highlight::_is_view_active {} {
    if {[_cmd IsSchematicViewActive]} {
        if {![catch {set active [IsSchematicViewActive]}]} {
            return [expr {$active ? 1 : 0}]
        }
    }
    if {[_cmd GetActivePage]} {
        if {![catch {set page [GetActivePage]}] && ![_is_null $page]} {
            return 1
        }
    }
    return 0
}

proc ::highlight::_activate_page {page_path {schematic_name ""} {page_name ""} {design_name ""}} {
    if {$design_name ne "" && [_cmd SelectPMItem]} {
        catch {SelectPMItem "./$design_name"}
        catch {SelectPMItem $design_name}
    }

    if {$schematic_name ne "" && [_cmd SelectPMItem]} {
        catch {SelectPMItem $schematic_name}
    }

    if {$schematic_name ne "" && $page_name ne "" && [_cmd OPage]} {
        catch {OPage $schematic_name $page_name}
        catch {update idletasks}
        if {[_is_view_active]} {
            return 1
        }
    }

    if {$schematic_name ne "" && $page_name ne "" && [_cmd NPage]} {
        if {![catch {NPage $schematic_name $page_name}]} {
            if {[_cmd OPage]} {
                catch {OPage $schematic_name $page_name}
            }
            catch {update idletasks}
            if {[_is_view_active]} {
                return 1
            }
        }
    }

    if {![_cmd SelectPMItem]} {
        return [_is_view_active]
    }

    foreach candidate [list $page_path "./$page_path"] {
        if {$candidate eq "" || [catch {SelectPMItem $candidate}]} {
            continue
        }
        foreach open_cmd {OpenPMItem ActivatePMItem OpenPage OpenSchematicPage} {
            if {[_cmd $open_cmd]} {
                catch {$open_cmd $candidate}
                catch {$open_cmd}
            }
        }
        if {[_cmd Menu]} {
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
        if {[_cmd $cmd_name] && ![catch [list $cmd_name]]} {
            return 1
        }
    }

    if {[_cmd Menu]} {
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

proc ::highlight::_zoom_selection {} {
    if {[_cmd ZoomSelection] && ![catch {ZoomSelection}]} {
        return 1
    }
    return 0
}

proc ::highlight::_select_part_on_active_page {refdes} {
    if {![_cmd GetActivePage] || ![_cmd SelectObjectById]} {
        error "GetActivePage/SelectObjectById command is not available"
    }

    set status [_status]
    set page [GetActivePage]
    if {$page eq "" || [_is_null $page]} {
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
        if {[_cmd DboPartInstToDboPlacedInst]} {
            set placed_inst [DboPartInstToDboPlacedInst $inst]
        }
        if {[_is_null $placed_inst]} {
            continue
        }

        if {![string equal -nocase [_refdes $placed_inst] $refdes]} {
            continue
        }

        set object_id [_id $placed_inst $status]
        if {$object_id eq "" || [dict exists $seen $object_id]} {
            continue
        }

        dict set seen $object_id 1
        if {![catch {SelectObjectById $object_id}]} {
            incr selected
        }
    }

    _safe_delete delete_DboPagePartInstsIter $part_iter
    return $selected
}

proc ::highlight::_select_net_on_active_page {net_name} {
    if {![_cmd GetActivePage] || ![_cmd SelectObjectById]} {
        error "GetActivePage/SelectObjectById command is not available"
    }

    set status [_status]
    set page [GetActivePage]
    if {$page eq "" || [_is_null $page]} {
        error "active page is not available"
    }

    set selected 0
    set wire_list {}
    set null_obj "NULL"

    set net_obj ""
    if {[_cmd DboTclHelper_sMakeCString]} {
        if {![catch {set cnet [DboTclHelper_sMakeCString $net_name]}]} {
            catch {set net_obj [$page GetNet $cnet $status]}
        }
    }
    if {$net_obj eq "" || [_is_null $net_obj]} {
        catch {set net_obj [$page GetNet $net_name $status]}
    }

    if {$net_obj ne "" && ![_is_null $net_obj]} {
        if {[_cmd DboNetWiresIter] && [info exists ::IterDefs_ALL]} {
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
            _safe_delete delete_DboNetWiresIter $wires_iter
            _safe_delete delete_DboPageWiresIter $wires_iter
        }

        if {[llength $wire_list] == 0} {
            set net_id [_id $net_obj $status]
            if {$net_id ne "" && ![catch {SelectObjectById $net_id}]} {
                incr selected
            }
        }
    }

    foreach wire $wire_list {
        set object_id [_id $wire $status]
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
    set status [_status]
    set design [_active_design $session $status]
    set design_name [_name $design]
    set matches {}
    set seen [dict create]
    set null_obj "NULL"

    set schem_iter [_schem_iter $design $status]
    while {1} {
        if {[catch {set view [$schem_iter NextView $status]}]} {
            break
        }
        if {$view eq $null_obj} {
            break
        }

        set schematic [_to_schematic $view]
        set schematic_name [_name $schematic]

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

            set page_id [_id $page $status]
            set page_name [_name $page]
            set page_path [_page_path $schematic_name $page_name]

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
                    if {[_cmd DboPartInstToDboPlacedInst]} {
                        set placed_inst [DboPartInstToDboPlacedInst $inst]
                    }
                    if {[_is_null $placed_inst]} {
                        continue
                    }
                    if {[string equal -nocase [_refdes $placed_inst] $refdes]} {
                        set found 1
                        break
                    }
                }
                _safe_delete delete_DboPagePartInstsIter $part_iter
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

        _safe_delete delete_DboSchematicPagesIter $pages_iter
    }

    _safe_delete delete_DboLibViewsIter $schem_iter
    return $matches
}

proc ::highlight::_find_net_pages {session net_name} {
    set status [_status]
    set design [_active_design $session $status]
    set design_name [_name $design]
    set matches {}
    set seen [dict create]
    set null_obj "NULL"

    set schem_iter [_schem_iter $design $status]
    while {1} {
        if {[catch {set view [$schem_iter NextView $status]}]} {
            break
        }
        if {$view eq $null_obj} {
            break
        }

        set schematic [_to_schematic $view]
        set schematic_name [_name $schematic]

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
            if {[_cmd DboTclHelper_sMakeCString]} {
                if {![catch {set cnet [DboTclHelper_sMakeCString $net_name]}]} {
                    catch {set net_obj [$page GetNet $cnet $status]}
                }
            }
            if {$net_obj eq "" || [_is_null $net_obj]} {
                catch {set net_obj [$page GetNet $net_name $status]}
            }
            if {$net_obj eq "" || [_is_null $net_obj]} {
                continue
            }

            set page_id [_id $page $status]
            set page_name [_name $page]
            set page_path [_page_path $schematic_name $page_name]

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

        _safe_delete delete_DboSchematicPagesIter $pages_iter
    }

    _safe_delete delete_DboLibViewsIter $schem_iter
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
        if {$page_selected > 0} {
            catch {_zoom_selection}
        }
    }

    if {$first_page ne ""} {
        catch {_activate_match_page $first_page}
        catch {_zoom_selection}
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

    if {[catch {set session [_session]} err]} {
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
            return "Part search: $pages, highlighted: $selected"
        }
        no_match {
            return "No matching part found: $refdes"
        }
        invalid_arg {
            error "part is required"
        }
        error {
            if {$reason eq ""} {
                error "part highlight failed"
            }
            error $reason
        }
        default {
            error "part highlight failed: $status"
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
            return "Net search: $pages, highlighted: $selected"
        }
        no_match {
            return "No matching net found: $net_name"
        }
        invalid_arg {
            error "net is required"
        }
        error {
            if {$reason eq ""} {
                error "net highlight failed"
            }
            error $reason
        }
        default {
            error "net highlight failed: $status"
        }
    }
}

proc ::highlight::_clear_response {} {
    set result [last_result]
    set status [dict get $result status]
    set reason [dict get $result reason]

    if {$status eq "ok"} {
        return "Cleared highlight"
    }
    if {$reason eq ""} {
        error "clear highlight failed"
    }
    error $reason
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
    ::coco_capture_highlight_part_impl $refdes
}

proc highlight_net {net_name} {
    ::coco_capture_highlight_net_impl $net_name
}

proc clear_highlight {} {
    ::coco_capture_clear_highlight_impl
}
