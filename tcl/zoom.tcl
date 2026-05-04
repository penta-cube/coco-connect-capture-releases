namespace eval ::zoom {
    variable _last_result [dict create status "idle" reason "" command ""]
}

proc ::zoom::_set_result {status reason command} {
    variable _last_result
    set _last_result [dict create \
        status $status \
        reason $reason \
        command $command]
}

proc ::zoom::last_result {} {
    variable _last_result
    return $_last_result
}

proc ::zoom::_run_capture_command {command_name} {
    if {![::coco_capture_utils::cmd_exists $command_name]} {
        return 0
    }
    if {![catch [list $command_name]]} {
        _set_result "ok" "" $command_name
        return 1
    }
    return 0
}

proc ::zoom::_run_menu_command {menu_name} {
    if {![::coco_capture_utils::cmd_exists Menu]} {
        return 0
    }
    if {![catch [list Menu $menu_name]]} {
        _set_result "ok" "" "Menu $menu_name"
        return 1
    }
    return 0
}

proc ::zoom::_run_first {capture_commands menu_commands} {
    foreach command_name $capture_commands {
        if {[_run_capture_command $command_name]} {
            catch {update idletasks}
            return 1
        }
    }

    foreach menu_name $menu_commands {
        if {[_run_menu_command $menu_name]} {
            catch {update idletasks}
            return 1
        }
    }

    return 0
}

proc ::zoom::selection {} {
    if {[_run_first \
        {ZoomSelection ZoomSelected ZoomToSelection} \
        {{View::Zoom::Selection} {View::Zoom Selection} {View::Zoom::To Selection} {View::Zoom To Selection}}]} {
        set selection_command [dict get [last_result] command]

        if {![::coco_capture_utils::cmd_exists ZoomIn]} {
            _set_result "error" "ZoomIn command is not available after $selection_command" $selection_command
            return 0
        }

        if {[catch {ZoomIn} err]} {
            _set_result "error" "ZoomIn failed after $selection_command: $err" $selection_command
            return 0
        }

        catch {update idletasks}
        _set_result "ok" "" "${selection_command} + ZoomIn"
        return 1
    }

    _set_result "error" "zoom selection command is not available" ""
    return 0
}

proc ::zoom::fit {} {
    if {[_run_first \
        {ZoomAll ZoomFit ZoomToFit FitAll} \
        {{View::Zoom::All} {View::Zoom All} {View::Zoom::Fit} {View::Zoom To Fit} {View::Fit}}]} {
        return 1
    }

    _set_result "error" "zoom fit command is not available" ""
    return 0
}

proc ::zoom::_response {bridge_command action} {
    set result [last_result]
    set status [dict get $result status]
    set reason [dict get $result reason]
    set command [dict get $result command]

    if {$status eq "ok"} {
        return [::coco_capture_utils::json_success \
            [::coco_capture_utils::json_object_from_pairs [list \
                [::coco_capture_utils::json_field_string command $bridge_command] \
                [::coco_capture_utils::json_field_string action $action] \
                [::coco_capture_utils::json_field_string capture_command $command]]]]
    }

    set message "zoom failed"
    if {$reason ne ""} {
        set message $reason
    }
    error [::coco_capture_utils::json_error \
        "zoom_failed" \
        $message \
        [::coco_capture_utils::json_object_from_pairs [list \
            [::coco_capture_utils::json_field_string command $bridge_command] \
            [::coco_capture_utils::json_field_string action $action]]]]
}

proc ::coco_capture_zoom_selection_impl {} {
    ::zoom::selection
    return [::zoom::_response "zoom_selection" "selection"]
}

proc ::coco_capture_zoom_fit_impl {} {
    ::zoom::fit
    return [::zoom::_response "zoom_fit" "fit"]
}

proc zoom_selection {} {
    return [::coco_capture_zoom_selection_impl]
}

proc zoom_fit {} {
    return [::coco_capture_zoom_fit_impl]
}
