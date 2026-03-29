namespace eval ::move {
    variable _last_result [dict create \
        status "idle" \
        reason "" \
        refdes "" \
        page_path "" \
        match_count 0 \
        old_x "" \
        old_y "" \
        new_x "" \
        new_y "" \
        dx 0 \
        dy 0 \
        operation ""]
}

proc ::move::_set_result {status reason refdes page_path match_count old_x old_y new_x new_y {extra_pairs {}}} {
    variable _last_result
    set _last_result [dict create \
        status $status \
        reason $reason \
        refdes $refdes \
        page_path $page_path \
        match_count $match_count \
        old_x $old_x \
        old_y $old_y \
        new_x $new_x \
        new_y $new_y \
        dx 0 \
        dy 0 \
        operation ""]
    foreach {key value} $extra_pairs {
        dict set _last_result $key $value
    }
}

proc ::move::last_result {} {
    variable _last_result
    return $_last_result
}

proc ::move::_require_capture_commands {commands message} {
    foreach cmd_name $commands {
        if {![::coco_capture_utils::cmd_exists $cmd_name]} {
            error $message
        }
    }
}

proc ::move::_require_utils {} {
    foreach helper {
        ::coco_capture_utils::active_design
        ::coco_capture_utils::cmd_exists
        ::coco_capture_utils::is_null
        ::coco_capture_utils::name
        ::coco_capture_utils::page_path
        ::coco_capture_utils::refdes
        ::coco_capture_utils::safe_delete
        ::coco_capture_utils::schem_iter
        ::coco_capture_utils::session
        ::coco_capture_utils::status
        ::coco_capture_utils::to_schematic
    } {
        if {![llength [info commands $helper]]} {
            error "utils.tcl must be loaded before move.tcl ($helper is missing)"
        }
    }
}

proc ::move::_find_part_matches {session refdes} {
    _require_utils

    set refdes [string trim $refdes]
    if {$refdes eq ""} {
        return {}
    }

    set status [::coco_capture_utils::status]
    set design [::coco_capture_utils::active_design $session $status]
    set design_name [::coco_capture_utils::name $design]
    set matches {}
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

            set page_name [::coco_capture_utils::name $page]
            set page_path [::coco_capture_utils::page_path $schematic_name $page_name]

            if {[catch {set part_iter [$page NewPartInstsIter $status]}]} {
                continue
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

                lappend matches [dict create \
                    design_name $design_name \
                    schematic_name $schematic_name \
                    page_name $page_name \
                    page_path $page_path \
                    page $page \
                    part_inst $inst \
                    placed_inst $placed_inst]
            }

            ::coco_capture_utils::safe_delete delete_DboPagePartInstsIter $part_iter
        }

        ::coco_capture_utils::safe_delete delete_DboSchematicPagesIter $pages_iter
    }

    ::coco_capture_utils::safe_delete delete_DboLibViewsIter $schem_iter
    return $matches
}

proc ::move::_resolve_part_target {refdes} {
    set refdes [string trim $refdes]
    if {$refdes eq ""} {
        _set_result "invalid_arg" "empty_refdes" "" "" 0 "" "" "" ""
        return ""
    }

    if {[catch {set session [::coco_capture_utils::session]} err]} {
        _set_result "error" "session_error: $err" $refdes "" 0 "" "" "" ""
        return ""
    }

    if {[catch {set matches [_find_part_matches $session $refdes]} err]} {
        _set_result "error" "search_error: $err" $refdes "" 0 "" "" "" ""
        return ""
    }

    set match_count [llength $matches]
    if {$match_count == 0} {
        _set_result "no_match" "" $refdes "" 0 "" "" "" ""
        return ""
    }
    if {$match_count != 1} {
        _set_result "ambiguous" "" $refdes "" $match_count "" "" "" ""
        return ""
    }

    set first_match [lindex $matches 0]
    return [dict create \
        refdes $refdes \
        page_path [dict get $first_match page_path] \
        match_count $match_count \
        page [dict get $first_match page] \
        part_inst [dict get $first_match part_inst] \
        placed_inst [dict get $first_match placed_inst]]
}

proc ::move::_parse_int {value reason_code} {
    set trimmed [string trim $value]
    if {$trimmed eq ""} {
        error $reason_code
    }
    if {![regexp {^-?\d+$} $trimmed]} {
        error $reason_code
    }
    return [expr {int($trimmed)}]
}

proc ::move::_set_target_result {target status reason old_x old_y new_x new_y {extra_pairs {}}} {
    _set_result \
        $status \
        $reason \
        [dict get $target refdes] \
        [dict get $target page_path] \
        [dict get $target match_count] \
        $old_x \
        $old_y \
        $new_x \
        $new_y \
        $extra_pairs
}

proc ::move::_eval_page {page} {
    set refreshed 0
    if {$page eq "" || [::coco_capture_utils::is_null $page]} {
        catch {update idletasks}
        catch {update}
        catch {ZoomRedraw}
        return 0
    }
    if {[::coco_capture_utils::cmd_exists DboTclHelper_sEvalPage]} {
        catch {DboTclHelper_sEvalPage $page}
        set refreshed 1
    }
    catch {update idletasks}
    catch {update}
    catch {ZoomRedraw}
    return $refreshed
}

proc ::move::_make_cpoint {x y} {
    _require_capture_commands {DboTclHelper_sMakeCPoint} "CPoint helper commands are not available"
    return [DboTclHelper_sMakeCPoint $x $y]
}

proc ::move::_cpoint_to_xy {point} {
    _require_capture_commands {DboTclHelper_sGetCPointX DboTclHelper_sGetCPointY} "CPoint helper commands are not available"
    return [list [DboTclHelper_sGetCPointX $point] [DboTclHelper_sGetCPointY $point]]
}

proc ::move::_try_get_location {obj} {
    if {$obj eq "" || [::coco_capture_utils::is_null $obj]} {
        return ""
    }

    set status [::coco_capture_utils::status]
    if {![catch {set point [$obj GetLocation $status]} err]} {
        if {$point ne "" && ![::coco_capture_utils::is_null $point]} {
            return [_cpoint_to_xy $point]
        }
    }

    return ""
}

proc ::move::_part_location {target} {
    set part_inst [dict get $target part_inst]
    set placed_inst [dict get $target placed_inst]

    set part_location [_try_get_location $part_inst]
    if {$part_location ne ""} {
        return $part_location
    }

    set placed_location [_try_get_location $placed_inst]
    if {$placed_location ne ""} {
        return $placed_location
    }

    _require_capture_commands {DboTclHelper_sGetCRectTopLeft DboTclHelper_sGetCRectBottomRight DboTclHelper_sGetCPointX DboTclHelper_sGetCPointY} "Bounding-box helper commands are not available"

    set status [::coco_capture_utils::status]
    if {[catch {set graphic_obj [$placed_inst GetDefiningGraphicObject $status]} err]} {
        error "GetDefiningGraphicObject failed: $err"
    }
    if {$graphic_obj eq "" || [::coco_capture_utils::is_null $graphic_obj]} {
        error "GetDefiningGraphicObject returned null"
    }

    if {[catch {set bbox [$graphic_obj GetBoundingBox]} err]} {
        error "GetBoundingBox failed: $err"
    }
    if {$bbox eq "" || [::coco_capture_utils::is_null $bbox]} {
        error "GetBoundingBox returned null"
    }

    if {[catch {set top_left [DboTclHelper_sGetCRectTopLeft $bbox]} err]} {
        error "DboTclHelper_sGetCRectTopLeft failed: $err"
    }
    if {[catch {set bottom_right [DboTclHelper_sGetCRectBottomRight $bbox]} err]} {
        error "DboTclHelper_sGetCRectBottomRight failed: $err"
    }

    lassign [_cpoint_to_xy $top_left] left_x top_y
    lassign [_cpoint_to_xy $bottom_right] right_x bottom_y
    return [list \
        [expr {int(($left_x + $right_x) / 2)}] \
        [expr {int(($top_y + $bottom_y) / 2)}]]
}

proc ::move::_try_absolute_move {part_inst x y} {
    set point ""
    if {[::coco_capture_utils::cmd_exists DboTclHelper_sMakeCPoint]} {
        catch {set point [_make_cpoint $x $y]}
    }

    set attempts {}
    if {[::coco_capture_utils::cmd_exists DboPartInst_SetLocation]} {
        if {$point ne "" && ![catch {DboPartInst_SetLocation $part_inst $point} err]} {
            return 1
        }
        if {[info exists err]} {
            lappend attempts "DboPartInst_SetLocation(part, point): $err"
        }
        if {![catch {DboPartInst_SetLocation $part_inst $x $y} err]} {
            return 1
        }
        lappend attempts "DboPartInst_SetLocation(part, x, y): $err"
    }

    if {$point ne "" && ![catch {$part_inst SetLocation $point} err]} {
        return 1
    }
    if {[info exists err] && $err ne ""} {
        lappend attempts "partInst.SetLocation(point): $err"
    }
    if {![catch {$part_inst SetLocation $x $y} err]} {
        return 1
    }
    if {[info exists err] && $err ne ""} {
        lappend attempts "partInst.SetLocation(x, y): $err"
    }

    if {[llength $attempts] == 0} {
        error "No absolute-move API is available"
    }
    error [join $attempts " | "]
}

proc ::move::_try_relative_move {target dx dy} {
    set part_inst [dict get $target part_inst]
    set placed_inst [dict get $target placed_inst]
    set point ""
    if {[::coco_capture_utils::cmd_exists DboTclHelper_sMakeCPoint]} {
        catch {set point [_make_cpoint $dx $dy]}
    }

    set attempts {}
    if {[::coco_capture_utils::cmd_exists DboPartInst_Move]} {
        if {![catch {DboPartInst_Move $part_inst $dx $dy} err]} {
            return 1
        }
        lappend attempts "DboPartInst_Move(part, dx, dy): $err"
        if {$point ne "" && ![catch {DboPartInst_Move $part_inst $point} err]} {
            return 1
        }
        if {$point ne ""} {
            lappend attempts "DboPartInst_Move(part, point): $err"
        }
    }

    if {![catch {$part_inst Move $dx $dy} err]} {
        return 1
    }
    lappend attempts "partInst.Move(dx, dy): $err"
    if {$point ne "" && ![catch {$part_inst Move $point} err]} {
        return 1
    }
    if {$point ne ""} {
        lappend attempts "partInst.Move(point): $err"
    }

    if {![::coco_capture_utils::is_null $placed_inst]} {
        if {[::coco_capture_utils::cmd_exists DboGraphicInstance_Move]} {
            if {![catch {DboGraphicInstance_Move $placed_inst $dx $dy} err]} {
                return 1
            }
            lappend attempts "DboGraphicInstance_Move(placed, dx, dy): $err"
            if {$point ne "" && ![catch {DboGraphicInstance_Move $placed_inst $point} err]} {
                return 1
            }
            if {$point ne ""} {
                lappend attempts "DboGraphicInstance_Move(placed, point): $err"
            }
        }
        if {![catch {Move $placed_inst $dx $dy} err]} {
            return 1
        }
        lappend attempts "Move(placed, dx, dy): $err"
    }

    error [join $attempts " | "]
}

proc ::move::part_move_absolute {refdes x y} {
    set target [_resolve_part_target $refdes]
    if {$target eq ""} {
        return 0
    }

    if {[catch {set target_x [_parse_int $x "invalid_x"]} reason]} {
        _set_target_result $target "invalid_arg" $reason "" "" "" ""
        return 0
    }
    if {[catch {set target_y [_parse_int $y "invalid_y"]} reason]} {
        _set_target_result $target "invalid_arg" $reason "" "" "" ""
        return 0
    }

    if {[catch {lassign [_part_location $target] old_x old_y} err]} {
        _set_target_result $target "error" "location_error: $err" "" "" "" ""
        return 0
    }

    set move_err ""
    if {[catch {_try_absolute_move [dict get $target part_inst] $target_x $target_y} move_err]} {
        set dx [expr {$target_x - $old_x}]
        set dy [expr {$target_y - $old_y}]
        if {[catch {_try_relative_move $target $dx $dy} fallback_err]} {
            _set_target_result $target "error" "move_error: $move_err | fallback: $fallback_err" $old_x $old_y "" ""
            return 0
        }
    }

    _eval_page [dict get $target page]
    if {[catch {lassign [_part_location $target] new_x new_y} err]} {
        _set_target_result $target "error" "location_error: $err" $old_x $old_y "" ""
        return 0
    }

    _set_target_result $target "ok" "" \
        $old_x \
        $old_y \
        $new_x \
        $new_y \
        [list \
            dx [expr {$new_x - $old_x}] \
            dy [expr {$new_y - $old_y}] \
            operation absolute]
    return 1
}

proc ::move::part_move_relative {refdes dx dy} {
    set target [_resolve_part_target $refdes]
    if {$target eq ""} {
        return 0
    }

    if {[catch {set delta_x [_parse_int $dx "invalid_dx"]} reason]} {
        _set_target_result $target "invalid_arg" $reason "" "" "" ""
        return 0
    }
    if {[catch {set delta_y [_parse_int $dy "invalid_dy"]} reason]} {
        _set_target_result $target "invalid_arg" $reason "" "" "" ""
        return 0
    }

    if {[catch {lassign [_part_location $target] old_x old_y} err]} {
        _set_target_result $target "error" "location_error: $err" "" "" "" ""
        return 0
    }

    if {[catch {_try_relative_move $target $delta_x $delta_y} err]} {
        _set_target_result $target "error" "move_error: $err" $old_x $old_y "" ""
        return 0
    }

    _eval_page [dict get $target page]
    if {[catch {lassign [_part_location $target] new_x new_y} err]} {
        _set_target_result $target "error" "location_error: $err" $old_x $old_y "" ""
        return 0
    }

    _set_target_result $target "ok" "" \
        $old_x \
        $old_y \
        $new_x \
        $new_y \
        [list \
            dx [expr {$new_x - $old_x}] \
            dy [expr {$new_y - $old_y}] \
            operation relative]
    return 1
}

proc ::move::_error_json {command code message detail_pairs} {
    error [::coco_capture_utils::json_error $code $message [::coco_capture_utils::json_object_from_pairs $detail_pairs]]
}

proc ::move::_part_move_response {command refdes} {
    set result [last_result]
    set status [dict get $result status]
    set reason [dict get $result reason]

    switch -- $status {
        ok {
            set payload_pairs [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes [dict get $result refdes]] \
                [::coco_capture_utils::json_field_string page_path [dict get $result page_path]] \
                [::coco_capture_utils::json_field_number match_count [dict get $result match_count]] \
                [::coco_capture_utils::json_field_number old_x [dict get $result old_x]] \
                [::coco_capture_utils::json_field_number old_y [dict get $result old_y]] \
                [::coco_capture_utils::json_field_number new_x [dict get $result new_x]] \
                [::coco_capture_utils::json_field_number new_y [dict get $result new_y]] \
                [::coco_capture_utils::json_field_number dx [dict get $result dx]] \
                [::coco_capture_utils::json_field_number dy [dict get $result dy]] \
                [::coco_capture_utils::json_field_string operation [dict get $result operation]]]
            return [::coco_capture_utils::json_success [::coco_capture_utils::json_object_from_pairs $payload_pairs]]
        }
        no_match {
            _error_json $command "no_match" "No matching part found" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes]]
        }
        ambiguous {
            _error_json $command "ambiguous_match" "Multiple matching parts found" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_number match_count [dict get $result match_count]]]
        }
        invalid_arg {
            if {$refdes eq ""} {
                _error_json $command "invalid_arg" "refdes is required" [list [::coco_capture_utils::json_field_string command $command]]
            }
            switch -- $reason {
                invalid_x {
                    _error_json $command "invalid_arg" "x must be an integer" [list \
                        [::coco_capture_utils::json_field_string command $command] \
                        [::coco_capture_utils::json_field_string refdes $refdes]]
                }
                invalid_y {
                    _error_json $command "invalid_arg" "y must be an integer" [list \
                        [::coco_capture_utils::json_field_string command $command] \
                        [::coco_capture_utils::json_field_string refdes $refdes]]
                }
                invalid_dx {
                    _error_json $command "invalid_arg" "dx must be an integer" [list \
                        [::coco_capture_utils::json_field_string command $command] \
                        [::coco_capture_utils::json_field_string refdes $refdes]]
                }
                invalid_dy {
                    _error_json $command "invalid_arg" "dy must be an integer" [list \
                        [::coco_capture_utils::json_field_string command $command] \
                        [::coco_capture_utils::json_field_string refdes $refdes]]
                }
                default {
                    _error_json $command "invalid_arg" "refdes is required" [list [::coco_capture_utils::json_field_string command $command]]
                }
            }
        }
        error {
            if {$reason eq ""} {
                set reason "Failed to move part"
            }
            _error_json $command "${command}_failed" $reason [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes]]
        }
        default {
            _error_json $command "${command}_failed" "Failed to move part: $status" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string status $status]]
        }
    }
}

proc ::coco_capture_part_move_absolute_impl {refdes x y} {
    ::move::part_move_absolute $refdes $x $y
    return [::move::_part_move_response "part_move_absolute" $refdes]
}

proc ::coco_capture_part_move_relative_impl {refdes dx dy} {
    ::move::part_move_relative $refdes $dx $dy
    return [::move::_part_move_response "part_move_relative" $refdes]
}

proc part_move_absolute {refdes x y} {
    return [::coco_capture_part_move_absolute_impl $refdes $x $y]
}

proc part_move_relative {refdes dx dy} {
    return [::coco_capture_part_move_relative_impl $refdes $dx $dy]
}
