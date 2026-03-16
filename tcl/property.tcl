namespace eval ::property {
    variable _last_result [dict create \
        status "idle" \
        reason "" \
        refdes "" \
        page_path "" \
        match_count 0 \
        property_name "" \
        property_count 0 \
        properties [dict create] \
        value "" \
        operation "" \
        display_mode "" \
        visible 0 \
        deleted 0 \
        location_x "" \
        location_y ""]
}

# Usage:
#   source utils.tcl
#   source property.tcl
#   list_part_properties U12
#   part_property_get U12 {PCB Footprint}
#   part_property_set U12 {PCB Footprint} SOIC8
#   part_property_delete U12 {PCB Footprint}
#   part_property_display_mode U12 {PCB Footprint} value_only

proc ::property::_set_result {status reason refdes page_path match_count property_name properties value {extra_pairs {}}} {
    variable _last_result
    set property_count 0
    if {[catch {set property_count [dict size $properties]}]} {
        set property_count 0
    }
    set _last_result [dict create \
        status $status \
        reason $reason \
        refdes $refdes \
        page_path $page_path \
        match_count $match_count \
        property_name $property_name \
        property_count $property_count \
        properties $properties \
        value $value \
        operation "" \
        display_mode "" \
        visible 0 \
        deleted 0 \
        location_x "" \
        location_y ""]
    foreach {key value} $extra_pairs {
        dict set _last_result $key $value
    }
}

proc ::property::last_result {} {
    variable _last_result
    return $_last_result
}

proc ::property::_require_capture_commands {commands message} {
    foreach cmd_name $commands {
        if {![::coco_capture_utils::cmd_exists $cmd_name]} {
            error $message
        }
    }
}

proc ::property::_release_handle {handle} {
    if {$handle ne "" && ![::coco_capture_utils::is_null $handle]} {
        catch {$handle -delete}
    }
}

proc ::property::_require_utils {} {
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
        ::coco_capture_utils::status_ok
        ::coco_capture_utils::to_schematic
    } {
        if {![llength [info commands $helper]]} {
            error "utils.tcl must be loaded before property.tcl ($helper is missing)"
        }
    }
}

proc ::property::_find_part_matches {session refdes} {
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
                    placed_inst $placed_inst]
            }

            ::coco_capture_utils::safe_delete delete_DboPagePartInstsIter $part_iter
        }

        ::coco_capture_utils::safe_delete delete_DboSchematicPagesIter $pages_iter
    }

    ::coco_capture_utils::safe_delete delete_DboLibViewsIter $schem_iter
    return $matches
}

proc ::property::_resolve_part_target {refdes {property_name ""}} {
    set refdes [string trim $refdes]
    set property_name [string trim $property_name]

    if {$refdes eq ""} {
        _set_result "invalid_arg" "empty_refdes" "" "" 0 $property_name [dict create] ""
        return ""
    }

    if {[catch {set session [::coco_capture_utils::session]} err]} {
        _set_result "error" "session_error: $err" $refdes "" 0 $property_name [dict create] ""
        return ""
    }

    if {[catch {set matches [_find_part_matches $session $refdes]} err]} {
        _set_result "error" "search_error: $err" $refdes "" 0 $property_name [dict create] ""
        return ""
    }

    if {[llength $matches] == 0} {
        _set_result "no_match" "" $refdes "" 0 $property_name [dict create] ""
        return ""
    }

    set first_match [lindex $matches 0]
    return [dict create \
        refdes $refdes \
        property_name $property_name \
        match_count [llength $matches] \
        page_path [dict get $first_match page_path] \
        page [dict get $first_match page] \
        placed_inst [dict get $first_match placed_inst]]
}

proc ::property::_ensure_property_name {target property_name} {
    set property_name [string trim $property_name]
    if {$property_name ne ""} {
        return 1
    }

    if {$target eq ""} {
        _set_result "invalid_arg" "empty_property_name" "" "" 0 "" [dict create] ""
    } else {
        _set_result "invalid_arg" "empty_property_name" \
            [dict get $target refdes] \
            [dict get $target page_path] \
            [dict get $target match_count] \
            "" \
            [dict create] \
            ""
    }
    return 0
}

proc ::property::_set_target_result {target status reason property_name properties value {extra_pairs {}}} {
    _set_result \
        $status \
        $reason \
        [dict get $target refdes] \
        [dict get $target page_path] \
        [dict get $target match_count] \
        $property_name \
        $properties \
        $value \
        $extra_pairs
}

proc ::property::_set_target_property_error {target property_name err} {
    _set_target_result $target "error" "property_error: $err" $property_name [dict create] ""
}

proc ::property::_set_target_no_property {target property_name} {
    _set_target_result $target "no_property" "" $property_name [dict create] ""
}

proc ::property::_get_effective_prop_string {obj property_name} {
    _require_capture_commands {DboTclHelper_sMakeCString DboTclHelper_sGetConstCharPtr} "CString helper commands are not available"

    set prop_name_c [DboTclHelper_sMakeCString $property_name]
    set prop_value_c [DboTclHelper_sMakeCString]

    if {[catch {set prop_status [$obj GetEffectivePropStringValue $prop_name_c $prop_value_c]} err]} {
        error "GetEffectivePropStringValue failed: $err"
    }

    if {![::coco_capture_utils::status_ok $prop_status]} {
        _release_handle $prop_status
        return [list 0 ""]
    }

    set value [string trim [DboTclHelper_sGetConstCharPtr $prop_value_c]]
    _release_handle $prop_status
    return [list 1 $value]
}

proc ::property::_set_effective_prop_string {obj property_name value} {
    _require_capture_commands {DboTclHelper_sMakeCString} "CString helper commands are not available"

    set prop_name_c [DboTclHelper_sMakeCString $property_name]
    set prop_value_c [DboTclHelper_sMakeCString $value]
    if {[catch {set status [$obj SetEffectivePropStringValue $prop_name_c $prop_value_c]} err]} {
        error "SetEffectivePropStringValue failed: $err"
    }
    if {$status ne "" && ![::coco_capture_utils::is_null $status] && ![::coco_capture_utils::status_ok $status]} {
        _release_handle $status
        error "SetEffectivePropStringValue returned a failure status"
    }
    _release_handle $status
    return 1
}

proc ::property::_delete_effective_prop {obj property_name} {
    _require_capture_commands {DboTclHelper_sMakeCString} "CString helper commands are not available"

    set prop_name_c [DboTclHelper_sMakeCString $property_name]
    if {[catch {set status [$obj DeleteEffectiveProp $prop_name_c]} err]} {
        error "DeleteEffectiveProp failed: $err"
    }
    if {$status ne "" && ![::coco_capture_utils::is_null $status] && ![::coco_capture_utils::status_ok $status]} {
        _release_handle $status
        error "DeleteEffectiveProp returned a failure status"
    }
    _release_handle $status
    return 1
}

proc ::property::_collect_effective_props {obj} {
    _require_capture_commands {DboTclHelper_sMakeCString DboTclHelper_sGetConstCharPtr} "CString helper commands are not available"
    _require_capture_commands {DboTclHelper_sMakeDboValueType DboTclHelper_sMakeInt} "Effective property iterator helpers are not available"

    set status [::coco_capture_utils::status]
    if {[catch {set props_iter [$obj NewEffectivePropsIter $status]} err]} {
        error "NewEffectivePropsIter failed: $err"
    }

    set prop_name_c [DboTclHelper_sMakeCString]
    set prop_value_c [DboTclHelper_sMakeCString]
    set prop_type [DboTclHelper_sMakeDboValueType]
    set editable [DboTclHelper_sMakeInt]
    set props [dict create]
    set iter_started 0

    while {1} {
        if {[catch {set step_status [$props_iter NextEffectiveProp $prop_name_c $prop_value_c $prop_type $editable]} err]} {
            if {!$iter_started} {
                ::coco_capture_utils::safe_delete delete_DboEffectivePropsIter $props_iter
                error "NextEffectiveProp failed: $err"
            }
            break
        }

        set iter_started 1
        if {![::coco_capture_utils::status_ok $step_status]} {
            _release_handle $step_status
            break
        }

        set prop_name [string trim [DboTclHelper_sGetConstCharPtr $prop_name_c]]
        set prop_value [string trim [DboTclHelper_sGetConstCharPtr $prop_value_c]]
        if {$prop_name ne ""} {
            dict set props $prop_name $prop_value
        }

        _release_handle $step_status
    }

    ::coco_capture_utils::safe_delete delete_DboEffectivePropsIter $props_iter
    return $props
}

proc ::property::_eval_page {page} {
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

proc ::property::_get_display_prop {placed_inst property_name} {
    _require_capture_commands {DboTclHelper_sMakeCString} "CString helper commands are not available"
    set status [::coco_capture_utils::status]
    set prop_name_c [DboTclHelper_sMakeCString $property_name]
    if {[catch {set display_prop [$placed_inst GetDisplayProp $prop_name_c $status]} err]} {
        error "GetDisplayProp failed: $err"
    }
    if {[::coco_capture_utils::is_null $display_prop]} {
        return ""
    }
    return $display_prop
}

proc ::property::_display_type_value_only {} {
    if {[info exists ::DboValue_VALUE_ONLY]} {
        return $::DboValue_VALUE_ONLY
    }
    return 1
}

proc ::property::_display_type_do_not_display {} {
    if {[info exists ::DboValue_DO_NOT_DISPLAY]} {
        return $::DboValue_DO_NOT_DISPLAY
    }
    return 0
}

proc ::property::_display_type_name_and_value {} {
    if {[info exists ::DboValue_NAME_AND_VALUE]} {
        return $::DboValue_NAME_AND_VALUE
    }
    return 2
}

proc ::property::_normalize_display_mode {mode} {
    set normalized [string tolower [string trim $mode]]
    switch -- $normalized {
        hidden -
        donotdisplay -
        do_not_display {
            return "hidden"
        }
        valueonly -
        value_only {
            return "value_only"
        }
        nameandvalue -
        name_and_value {
            return "name_and_value"
        }
        default {
            return ""
        }
    }
}

proc ::property::_display_mode_to_type {mode} {
    switch -- $mode {
        hidden {
            return [_display_type_do_not_display]
        }
        value_only {
            return [_display_type_value_only]
        }
        name_and_value {
            return [_display_type_name_and_value]
        }
        default {
            error "Unsupported display mode: $mode"
        }
    }
}

proc ::property::_display_mode_from_type {display_type} {
    switch -- $display_type {
        0 {
            return "hidden"
        }
        2 {
            return "name_and_value"
        }
        1 -
        3 -
        4 {
            return "value_only"
        }
        default {
            return "hidden"
        }
    }
}

proc ::property::_make_cpoint {x y} {
    _require_capture_commands {DboTclHelper_sMakeCPoint} "CPoint helper commands are not available"
    return [DboTclHelper_sMakeCPoint $x $y]
}

proc ::property::_cpoint_to_xy {point} {
    _require_capture_commands {DboTclHelper_sGetCPointX DboTclHelper_sGetCPointY} "CPoint helper commands are not available"
    return [list [DboTclHelper_sGetCPointX $point] [DboTclHelper_sGetCPointY $point]]
}

proc ::property::_get_display_location {display_prop} {
    set status [::coco_capture_utils::status]
    if {[catch {set point [$display_prop GetLocation $status]} err]} {
        error "GetLocation failed: $err"
    }
    if {$point eq "" || [::coco_capture_utils::is_null $point]} {
        return [list "" ""]
    }
    return [_cpoint_to_xy $point]
}

proc ::property::_get_display_type {display_prop} {
    set status [::coco_capture_utils::status]
    if {[catch {set display_type [$display_prop GetDisplayType $status]} err]} {
        error "GetDisplayType failed: $err"
    }
    return $display_type
}

proc ::property::_get_display_state {placed_inst property_name} {
    set display_prop [_get_display_prop $placed_inst $property_name]
    if {$display_prop eq ""} {
        return [dict create \
            display_mode "hidden" \
            visible 0 \
            location_x "" \
            location_y ""]
    }

    set display_mode "hidden"
    if {![catch {set display_type [_get_display_type $display_prop]}]} {
        set display_mode [_display_mode_from_type $display_type]
    }

    set location_x ""
    set location_y ""
    if {![catch {lassign [_get_display_location $display_prop] location_x location_y}]} {
        # keep parsed location values
    }

    return [dict create \
        display_mode $display_mode \
        visible [expr {$display_mode ne "hidden"}] \
        location_x $location_x \
        location_y $location_y]
}

proc ::property::_default_display_location {placed_inst} {
    _require_capture_commands {DboTclHelper_sGetCRectTopLeft DboTclHelper_sGetCRectBottomRight DboTclHelper_sGetCPointX DboTclHelper_sGetCPointY} "Display-property helper commands are not available"

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
    set center_x [expr {int(($left_x + $right_x) / 2)}]
    set center_y [expr {int(($top_y + $bottom_y) / 2)}]
    return [list $center_x $center_y]
}

proc ::property::_create_display_prop {placed_inst property_name} {
    _require_capture_commands {DboTclHelper_sMakeCString DboTclHelper_sMakeLOGFONT} "Display-property helper commands are not available"

    set status [::coco_capture_utils::status]
    set prop_name_c [DboTclHelper_sMakeCString $property_name]
    set location [_default_display_location $placed_inst]
    lassign $location location_x location_y
    set point [_make_cpoint $location_x $location_y]
    set rotation 0
    set logfont [DboTclHelper_sMakeLOGFONT]
    set color 0

    if {[catch {set display_prop [$placed_inst NewDisplayProp $status $prop_name_c $point $rotation $logfont $color]} err]} {
        error "NewDisplayProp failed: $err"
    }
    if {$display_prop eq "" || [::coco_capture_utils::is_null $display_prop]} {
        error "NewDisplayProp returned null"
    }
    return $display_prop
}

proc ::property::_set_display_mode {placed_inst page property_name mode} {
    set mode [_normalize_display_mode $mode]
    if {$mode eq ""} {
        error "display mode must be one of: hidden, value_only, name_and_value"
    }

    set display_prop [_get_display_prop $placed_inst $property_name]
    if {$display_prop eq ""} {
        if {$mode eq "hidden"} {
            return 0
        }
        set display_prop [_create_display_prop $placed_inst $property_name]
    }

    set display_type [_display_mode_to_type $mode]

    if {[catch {$display_prop SetDisplayType $display_type} err]} {
        error "SetDisplayType failed: $err"
    }

    _eval_page $page
    return 1
}

proc ::property::part_properties {refdes} {
    set target [_resolve_part_target $refdes]
    if {$target eq ""} {
        return [dict create]
    }

    if {[catch {set props [_collect_effective_props [dict get $target placed_inst]]} err]} {
        _set_target_property_error $target "" $err
        return [dict create]
    }

    _set_target_result $target "ok" "" "" $props ""
    return $props
}

proc ::property::part_property_get {refdes property_name} {
    set target [_resolve_part_target $refdes $property_name]
    if {$target eq ""} {
        return ""
    }
    if {![_ensure_property_name $target $property_name]} {
        return ""
    }

    if {[catch {set found_and_value [_get_effective_prop_string [dict get $target placed_inst] $property_name]} err]} {
        _set_target_property_error $target $property_name $err
        return ""
    }

    if {![lindex $found_and_value 0]} {
        _set_target_no_property $target $property_name
        return ""
    }

    set value [lindex $found_and_value 1]
    _set_target_result $target "ok" "" $property_name [dict create $property_name $value] $value
    return $value
}

proc ::property::part_property_set {refdes property_name value} {
    set target [_resolve_part_target $refdes $property_name]
    if {$target eq ""} {
        return ""
    }
    if {![_ensure_property_name $target $property_name]} {
        return ""
    }

    set operation "update"
    if {[catch {set found_and_value [_get_effective_prop_string [dict get $target placed_inst] $property_name]} err]} {
        _set_target_property_error $target $property_name $err
        return ""
    }
    if {![lindex $found_and_value 0]} {
        set operation "create"
    }

    if {[catch {_set_effective_prop_string [dict get $target placed_inst] $property_name $value} err]} {
        _set_target_property_error $target $property_name $err
        return ""
    }

    _eval_page [dict get $target page]
    _set_target_result $target "ok" "" \
        $property_name \
        [dict create $property_name $value] \
        $value \
        [list operation $operation]
    return $value
}

proc ::property::part_property_delete {refdes property_name} {
    set target [_resolve_part_target $refdes $property_name]
    if {$target eq ""} {
        return 0
    }
    if {![_ensure_property_name $target $property_name]} {
        return 0
    }

    if {[catch {set found_and_value [_get_effective_prop_string [dict get $target placed_inst] $property_name]} err]} {
        _set_target_property_error $target $property_name $err
        return 0
    }
    if {![lindex $found_and_value 0]} {
        _set_target_no_property $target $property_name
        return 0
    }

    # Best-effort hide first so deleting a displayed property does not leave stale text behind.
    catch {_set_display_mode [dict get $target placed_inst] [dict get $target page] $property_name hidden}

    if {[catch {_delete_effective_prop [dict get $target placed_inst] $property_name} err]} {
        _set_target_property_error $target $property_name $err
        return 0
    }

    _eval_page [dict get $target page]
    _set_target_result $target "ok" "" \
        $property_name \
        [dict create] \
        "" \
        [list operation delete deleted 1]
    return 1
}

proc ::property::part_property_display_mode {refdes property_name mode} {
    set target [_resolve_part_target $refdes $property_name]
    if {$target eq ""} {
        return 0
    }
    if {![_ensure_property_name $target $property_name]} {
        return 0
    }

    set normalized_mode [_normalize_display_mode $mode]
    if {$normalized_mode eq ""} {
        _set_target_result $target "invalid_arg" "invalid_display_mode" $property_name [dict create] ""
        return 0
    }

    if {[catch {set found_and_value [_get_effective_prop_string [dict get $target placed_inst] $property_name]} err]} {
        _set_target_property_error $target $property_name $err
        return 0
    }
    if {![lindex $found_and_value 0]} {
        _set_target_no_property $target $property_name
        return 0
    }

    if {[catch {_set_display_mode [dict get $target placed_inst] [dict get $target page] $property_name $normalized_mode} err]} {
        _set_target_result $target "error" "display_error: $err" $property_name [dict create $property_name [lindex $found_and_value 1]] [lindex $found_and_value 1]
        return 0
    }

    set display_state [_get_display_state [dict get $target placed_inst] $property_name]

    _set_target_result $target "ok" "" \
        $property_name \
        [dict create $property_name [lindex $found_and_value 1]] \
        [lindex $found_and_value 1] \
        [list \
            operation display_mode \
            display_mode [dict get $display_state display_mode] \
            visible [dict get $display_state visible] \
            location_x [dict get $display_state location_x] \
            location_y [dict get $display_state location_y]]
    return 1
}

proc ::property::_error_json {command code message detail_pairs} {
    error [::coco_capture_utils::json_error $code $message [::coco_capture_utils::json_object_from_pairs $detail_pairs]]
}

proc ::property::_part_properties_response {refdes} {
    set result [last_result]
    set status [dict get $result status]
    set reason [dict get $result reason]
    set command "part_properties"

    switch -- $status {
        ok {
            set payload_pairs [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes [dict get $result refdes]] \
                [::coco_capture_utils::json_field_string page_path [dict get $result page_path]] \
                [::coco_capture_utils::json_field_number match_count [dict get $result match_count]] \
                [::coco_capture_utils::json_field_number property_count [dict get $result property_count]] \
                [::coco_capture_utils::json_field_json properties [::coco_capture_utils::json_from_string_dict [dict get $result properties]]]]
            return [::coco_capture_utils::json_success [::coco_capture_utils::json_object_from_pairs $payload_pairs]]
        }
        no_match {
            set detail_pairs [list [::coco_capture_utils::json_field_string command $command]]
            if {$refdes ne ""} {
                lappend detail_pairs [::coco_capture_utils::json_field_string refdes $refdes]
            }
            _error_json $command "no_match" "No matching part found" $detail_pairs
        }
        invalid_arg {
            _error_json $command "invalid_arg" "refdes is required" [list [::coco_capture_utils::json_field_string command $command]]
        }
        error {
            set detail_pairs [list [::coco_capture_utils::json_field_string command $command]]
            if {$refdes ne ""} {
                lappend detail_pairs [::coco_capture_utils::json_field_string refdes $refdes]
            }
            if {$reason eq ""} {
                set reason "Failed to list part properties"
            }
            _error_json $command "part_properties_failed" $reason $detail_pairs
        }
        default {
            set detail_pairs [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string status $status]]
            if {$refdes ne ""} {
                lappend detail_pairs [::coco_capture_utils::json_field_string refdes $refdes]
            }
            _error_json $command "part_properties_failed" "Failed to list part properties: $status" $detail_pairs
        }
    }
}

proc ::property::_part_property_get_response {refdes property_name} {
    set result [last_result]
    set status [dict get $result status]
    set reason [dict get $result reason]
    set command "part_property_get"

    switch -- $status {
        ok {
            set payload_pairs [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes [dict get $result refdes]] \
                [::coco_capture_utils::json_field_string page_path [dict get $result page_path]] \
                [::coco_capture_utils::json_field_number match_count [dict get $result match_count]] \
                [::coco_capture_utils::json_field_string property [dict get $result property_name]] \
                [::coco_capture_utils::json_field_string value [dict get $result value]]]
            return [::coco_capture_utils::json_success [::coco_capture_utils::json_object_from_pairs $payload_pairs]]
        }
        no_match {
            _error_json $command "no_match" "No matching part found" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name]]
        }
        no_property {
            _error_json $command "no_property" "No matching property found" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name]]
        }
        invalid_arg {
            if {$refdes eq ""} {
                _error_json $command "invalid_arg" "refdes is required" [list [::coco_capture_utils::json_field_string command $command]]
            }
            _error_json $command "invalid_arg" "property is required" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes]]
        }
        error {
            if {$reason eq ""} {
                set reason "Failed to get part property"
            }
            _error_json $command "part_property_get_failed" $reason [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name]]
        }
        default {
            _error_json $command "part_property_get_failed" "Failed to get part property: $status" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name] \
                [::coco_capture_utils::json_field_string status $status]]
        }
    }
}

proc ::property::_part_property_set_response {refdes property_name} {
    set result [last_result]
    set status [dict get $result status]
    set reason [dict get $result reason]
    set command "part_property_set"

    switch -- $status {
        ok {
            set payload_pairs [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes [dict get $result refdes]] \
                [::coco_capture_utils::json_field_string page_path [dict get $result page_path]] \
                [::coco_capture_utils::json_field_number match_count [dict get $result match_count]] \
                [::coco_capture_utils::json_field_string property [dict get $result property_name]] \
                [::coco_capture_utils::json_field_string value [dict get $result value]] \
                [::coco_capture_utils::json_field_string operation [dict get $result operation]]]
            return [::coco_capture_utils::json_success [::coco_capture_utils::json_object_from_pairs $payload_pairs]]
        }
        no_match {
            _error_json $command "no_match" "No matching part found" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name]]
        }
        invalid_arg {
            if {$refdes eq ""} {
                _error_json $command "invalid_arg" "refdes is required" [list [::coco_capture_utils::json_field_string command $command]]
            }
            _error_json $command "invalid_arg" "property is required" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes]]
        }
        error {
            if {$reason eq ""} {
                set reason "Failed to set part property"
            }
            _error_json $command "part_property_set_failed" $reason [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name]]
        }
        default {
            _error_json $command "part_property_set_failed" "Failed to set part property: $status" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name] \
                [::coco_capture_utils::json_field_string status $status]]
        }
    }
}

proc ::property::_part_property_delete_response {refdes property_name} {
    set result [last_result]
    set status [dict get $result status]
    set reason [dict get $result reason]
    set command "part_property_delete"

    switch -- $status {
        ok {
            set payload_pairs [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes [dict get $result refdes]] \
                [::coco_capture_utils::json_field_string page_path [dict get $result page_path]] \
                [::coco_capture_utils::json_field_number match_count [dict get $result match_count]] \
                [::coco_capture_utils::json_field_string property [dict get $result property_name]] \
                [::coco_capture_utils::json_field_bool deleted [dict get $result deleted]]]
            return [::coco_capture_utils::json_success [::coco_capture_utils::json_object_from_pairs $payload_pairs]]
        }
        no_match {
            _error_json $command "no_match" "No matching part found" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name]]
        }
        no_property {
            _error_json $command "no_property" "No matching property found" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name]]
        }
        invalid_arg {
            if {$refdes eq ""} {
                _error_json $command "invalid_arg" "refdes is required" [list [::coco_capture_utils::json_field_string command $command]]
            }
            _error_json $command "invalid_arg" "property is required" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes]]
        }
        error {
            if {$reason eq ""} {
                set reason "Failed to delete part property"
            }
            _error_json $command "part_property_delete_failed" $reason [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name]]
        }
        default {
            _error_json $command "part_property_delete_failed" "Failed to delete part property: $status" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name] \
                [::coco_capture_utils::json_field_string status $status]]
        }
    }
}

proc ::property::_part_property_visibility_response {command refdes property_name} {
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
                [::coco_capture_utils::json_field_string property [dict get $result property_name]] \
                [::coco_capture_utils::json_field_string value [dict get $result value]] \
                [::coco_capture_utils::json_field_string display_mode [dict get $result display_mode]] \
                [::coco_capture_utils::json_field_bool visible [dict get $result visible]]]
            if {[dict get $result location_x] ne "" && [dict get $result location_y] ne ""} {
                lappend payload_pairs \
                    [::coco_capture_utils::json_field_number location_x [dict get $result location_x]] \
                    [::coco_capture_utils::json_field_number location_y [dict get $result location_y]]
            }
            return [::coco_capture_utils::json_success [::coco_capture_utils::json_object_from_pairs $payload_pairs]]
        }
        no_match {
            _error_json $command "no_match" "No matching part found" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name]]
        }
        no_property {
            _error_json $command "no_property" "No matching property found" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name]]
        }
        invalid_arg {
            if {$refdes eq ""} {
                _error_json $command "invalid_arg" "refdes is required" [list [::coco_capture_utils::json_field_string command $command]]
            }
            if {$reason eq "invalid_display_mode"} {
                _error_json $command "invalid_arg" "display mode must be one of: hidden, value_only, name_and_value" [list \
                    [::coco_capture_utils::json_field_string command $command] \
                    [::coco_capture_utils::json_field_string refdes $refdes] \
                    [::coco_capture_utils::json_field_string property $property_name]]
            }
            _error_json $command "invalid_arg" "property is required" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes]]
        }
        error {
            if {$reason eq ""} {
                set reason "Failed to update part property display mode"
            }
            _error_json $command "part_property_display_mode_failed" $reason [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name]]
        }
        default {
            _error_json $command "part_property_display_mode_failed" "Failed to update part property display mode: $status" [list \
                [::coco_capture_utils::json_field_string command $command] \
                [::coco_capture_utils::json_field_string refdes $refdes] \
                [::coco_capture_utils::json_field_string property $property_name] \
                [::coco_capture_utils::json_field_string status $status]]
        }
    }
}

# Bridge hook functions consumed by coco_capture_bootstrap.tcl
proc ::coco_capture_list_part_properties_impl {refdes} {
    ::property::part_properties $refdes
    return [::property::_part_properties_response $refdes]
}

proc ::coco_capture_part_property_get_impl {refdes property_name} {
    ::property::part_property_get $refdes $property_name
    return [::property::_part_property_get_response $refdes $property_name]
}

proc ::coco_capture_part_property_set_impl {refdes property_name value} {
    ::property::part_property_set $refdes $property_name $value
    return [::property::_part_property_set_response $refdes $property_name]
}

proc ::coco_capture_part_property_delete_impl {refdes property_name} {
    ::property::part_property_delete $refdes $property_name
    return [::property::_part_property_delete_response $refdes $property_name]
}

proc ::coco_capture_part_property_display_mode_impl {refdes property_name mode} {
    ::property::part_property_display_mode $refdes $property_name $mode
    return [::property::_part_property_visibility_response "part_property_display_mode" $refdes $property_name]
}

# Optional direct wrappers for manual Tcl usage
proc list_part_properties {refdes} {
    return [::coco_capture_list_part_properties_impl $refdes]
}

proc part_property_get {refdes property_name} {
    return [::coco_capture_part_property_get_impl $refdes $property_name]
}

proc part_property_set {refdes property_name value} {
    return [::coco_capture_part_property_set_impl $refdes $property_name $value]
}

proc part_property_delete {refdes property_name} {
    return [::coco_capture_part_property_delete_impl $refdes $property_name]
}

proc part_property_display_mode {refdes property_name mode} {
    return [::coco_capture_part_property_display_mode_impl $refdes $property_name $mode]
}
