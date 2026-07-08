# coco_capture_bootstrap.tcl
#
# Minimal Capture-side Tcl bridge for coco-connect-capture.
# Line protocol (UTF-8):
#   request:  id<TAB>cmd<TAB>arg<TAB>token\n
#   response: id<TAB>json\n

namespace eval ::coco_capture_bridge {
  variable host "127.0.0.1"
  variable port 49500
  variable token ""
  variable server_sock ""
  variable impl_loaded 0
}

proc ::coco_capture_bridge::sanitize_field {text} {
  return [string map [list "\t" " " "\n" " " "\r" " "] $text]
}

proc ::coco_capture_bridge::source_utf8 {file_path} {
  set fd [open $file_path r]
  fconfigure $fd -encoding utf-8 -translation auto
  set script [read $fd]
  close $fd
  uplevel #0 $script
}

proc ::coco_capture_bridge::load_default_impl {} {
  variable impl_loaded
  if {$impl_loaded} {
    return 1
  }

  set dir [file normalize [file dirname [info script]]]
  set loaded_any 0
  foreach impl_name {utils.tcl highlight.tcl property.tcl find_replace.tcl list_ports.tcl list_offpage_connectors.tcl get_text_objects.tcl move.tcl net.tcl auto_arrange_text.tcl zoom.tcl} {
    set impl_file [file join $dir $impl_name]
    if {![file exists $impl_file]} {
      continue
    }

    source_utf8 $impl_file
    set loaded_any 1
  }

  if {$loaded_any} {
    set impl_loaded 1
    return 1
  }

  return 0
}

proc ::coco_capture_bridge::send_response {chan id message} {
  set safe_id [sanitize_field $id]
  set safe_message [sanitize_field $message]

  catch {
    puts $chan "${safe_id}\t${safe_message}"
    flush $chan
  }
  catch {close $chan}
}

proc ::coco_capture_bridge::highlight_net {net} {
  if {[llength [info commands ::coco_capture_highlight_net_impl]] > 0} {
    return [::coco_capture_highlight_net_impl $net]
  }

  error [::coco_capture_utils::json_error "missing_impl" "No net-highlight implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "highlight_net"]]]]
}

proc ::coco_capture_bridge::highlight_part {part} {
  if {[llength [info commands ::coco_capture_highlight_part_impl]] > 0} {
    return [::coco_capture_highlight_part_impl $part]
  }

  error [::coco_capture_utils::json_error "missing_impl" "No part-highlight implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "highlight_part"]]]]
}

proc ::coco_capture_bridge::clear_highlight {} {
  if {[llength [info commands ::coco_capture_clear_highlight_impl]] > 0} {
    return [::coco_capture_clear_highlight_impl]
  }

  error [::coco_capture_utils::json_error "missing_impl" "No clear-highlight implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "clear_highlight"]]]]
}

proc ::coco_capture_bridge::list_part_properties {part} {
  if {[llength [info commands ::coco_capture_list_part_properties_impl]] > 0} {
    return [::coco_capture_list_part_properties_impl $part]
  }

  error [::coco_capture_utils::json_error "missing_impl" "No part-properties implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_properties"]]]]
}

proc ::coco_capture_bridge::split_property_arg {cmd arg min_fields} {
  set fields [split $arg "|"]
  if {[llength $fields] < $min_fields} {
    error [::coco_capture_utils::json_error "invalid_arg" "arg format is invalid for $cmd" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command $cmd] [::coco_capture_utils::json_field_string arg $arg]]]]
  }
  return $fields
}

proc ::coco_capture_bridge::part_property_get {arg} {
  if {[llength [info commands ::coco_capture_part_property_get_impl]] == 0} {
    error [::coco_capture_utils::json_error "missing_impl" "No part-property-get implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_get"]]]]
  }

  set fields [split_property_arg "part_property_get" $arg 2]
  set part [string trim [lindex $fields 0]]
  set property_name [string trim [join [lrange $fields 1 end] "|"]]
  if {$part eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "refdes is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_get"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }
  if {$property_name eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "property is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_get"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }

  return [::coco_capture_part_property_get_impl $part $property_name]
}

proc ::coco_capture_bridge::part_property_set {arg} {
  if {[llength [info commands ::coco_capture_part_property_set_impl]] == 0} {
    error [::coco_capture_utils::json_error "missing_impl" "No part-property-set implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_set"]]]]
  }

  set fields [split_property_arg "part_property_set" $arg 3]
  set part [string trim [lindex $fields 0]]
  set property_name [string trim [lindex $fields 1]]
  set value [join [lrange $fields 2 end] "|"]
  if {$part eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "refdes is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_set"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }
  if {$property_name eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "property is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_set"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }

  return [::coco_capture_part_property_set_impl $part $property_name $value]
}

proc ::coco_capture_bridge::part_property_delete {arg} {
  if {[llength [info commands ::coco_capture_part_property_delete_impl]] == 0} {
    error [::coco_capture_utils::json_error "missing_impl" "No part-property-delete implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_delete"]]]]
  }

  set fields [split_property_arg "part_property_delete" $arg 2]
  set part [string trim [lindex $fields 0]]
  set property_name [string trim [join [lrange $fields 1 end] "|"]]
  if {$part eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "refdes is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_delete"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }
  if {$property_name eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "property is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_delete"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }

  return [::coco_capture_part_property_delete_impl $part $property_name]
}

proc ::coco_capture_bridge::part_property_display_mode {arg} {
  if {[llength [info commands ::coco_capture_part_property_display_mode_impl]] == 0} {
    error [::coco_capture_utils::json_error "missing_impl" "No part-property-display-mode implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_display_mode"]]]]
  }

  set fields [split_property_arg "part_property_display_mode" $arg 3]
  set part [string trim [lindex $fields 0]]
  set property_name [string trim [lindex $fields 1]]
  set mode [string trim [join [lrange $fields 2 end] "|"]]
  if {$part eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "refdes is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_display_mode"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }
  if {$property_name eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "property is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_display_mode"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }
  if {$mode eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "display mode is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_property_display_mode"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }

  return [::coco_capture_part_property_display_mode_impl $part $property_name $mode]
}

proc ::coco_capture_bridge::split_move_arg {cmd arg} {
  set fields [split $arg "|"]
  if {[llength $fields] < 3} {
    error [::coco_capture_utils::json_error "invalid_arg" "arg format is invalid for $cmd" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command $cmd] [::coco_capture_utils::json_field_string arg $arg]]]]
  }
  return $fields
}

proc ::coco_capture_bridge::part_move_absolute {arg} {
  if {[llength [info commands ::coco_capture_part_move_absolute_impl]] == 0} {
    error [::coco_capture_utils::json_error "missing_impl" "No part-move-absolute implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_move_absolute"]]]]
  }

  set fields [split_move_arg "part_move_absolute" $arg]
  set part [string trim [lindex $fields 0]]
  set x [string trim [lindex $fields 1]]
  set y [string trim [join [lrange $fields 2 end] "|"]]
  if {$part eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "refdes is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_move_absolute"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }
  if {$x eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "x is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_move_absolute"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }
  if {$y eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "y is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_move_absolute"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }

  return [::coco_capture_part_move_absolute_impl $part $x $y]
}

proc ::coco_capture_bridge::part_move_relative {arg} {
  if {[llength [info commands ::coco_capture_part_move_relative_impl]] == 0} {
    error [::coco_capture_utils::json_error "missing_impl" "No part-move-relative implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_move_relative"]]]]
  }

  set fields [split_move_arg "part_move_relative" $arg]
  set part [string trim [lindex $fields 0]]
  set dx [string trim [lindex $fields 1]]
  set dy [string trim [join [lrange $fields 2 end] "|"]]
  if {$part eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "refdes is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_move_relative"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }
  if {$dx eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "dx is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_move_relative"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }
  if {$dy eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "dy is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_move_relative"] [::coco_capture_utils::json_field_string arg $arg]]]]
  }

  return [::coco_capture_part_move_relative_impl $part $dx $dy]
}

proc ::coco_capture_bridge::rename_net {arg} {
  if {[llength [info commands ::coco_capture_rename_net_impl]] == 0} {
    error [::coco_capture_utils::json_error "missing_impl" "No rename-net implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "rename_net"]]]]
  }

  set fields [split_property_arg "rename_net" $arg 2]
  set old_name [string trim [lindex $fields 0]]
  set new_name [string trim [lindex $fields 1]]

  if {$old_name eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "old net name is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "rename_net"]]]]
  }
  if {$new_name eq ""} {
    error [::coco_capture_utils::json_error "invalid_arg" "new net name is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "rename_net"]]]]
  }

  return [::coco_capture_rename_net_impl $old_name $new_name]
}

proc ::coco_capture_bridge::auto_arrange_text {page} {
  if {[llength [info commands ::coco_auto_arrange_text_impl]] == 0} {
    error [::coco_capture_utils::json_error "missing_impl" "No auto-arrange-text implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "auto_arrange_text"]]]]
  }

  return [::coco_auto_arrange_text_impl $page]
}

proc ::coco_capture_bridge::zoom_selection {} {
  if {[llength [info commands ::coco_capture_zoom_selection_impl]] == 0} {
    error [::coco_capture_utils::json_error "missing_impl" "No zoom-selection implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "zoom_selection"]]]]
  }

  return [::coco_capture_zoom_selection_impl]
}

proc ::coco_capture_bridge::zoom_fit {} {
  if {[llength [info commands ::coco_capture_zoom_fit_impl]] == 0} {
    error [::coco_capture_utils::json_error "missing_impl" "No zoom-fit implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "zoom_fit"]]]]
  }

  return [::coco_capture_zoom_fit_impl]
}


proc ::coco_capture_bridge::find_text {query} {
  if {[llength [info commands ::coco_capture_find_text_impl]] > 0} {
    return [::coco_capture_find_text_impl $query]
  }
  error [::coco_capture_utils::json_error "missing_impl" "No find-text implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "find_text"]]]]
}

proc ::coco_capture_bridge::list_ports {arg} {
  if {[llength [info commands ::coco_capture_list_ports_impl]] > 0} {
    return [::coco_capture_list_ports_impl $arg]
  }
  error [::coco_capture_utils::json_error "missing_impl" "No list-ports implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "list_ports"]]]]
}

proc ::coco_capture_bridge::list_offpage_connectors {arg} {
  if {[llength [info commands ::coco_capture_list_offpage_connectors_impl]] > 0} {
    return [::coco_capture_list_offpage_connectors_impl $arg]
  }
  error [::coco_capture_utils::json_error "missing_impl" "No list-offpage-connectors implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "list_offpage_connectors"]]]]
}

proc ::coco_capture_bridge::get_text_objects {arg} {
  if {[llength [info commands ::coco_capture_get_text_objects_impl]] > 0} {
    return [::coco_capture_get_text_objects_impl $arg]
  }
  error [::coco_capture_utils::json_error "missing_impl" "No get-text-objects implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "get_text_objects"]]]]
}

proc ::coco_capture_bridge::find_replace {arg} {
  if {[llength [info commands ::coco_capture_find_replace_impl]] > 0} {
    return [::coco_capture_find_replace_impl $arg]
  }
  error [::coco_capture_utils::json_error "missing_impl" "No find-replace implementation found" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "find_replace"]]]]
}

proc ::coco_capture_bridge::dispatch {cmd arg} {
  switch -- $cmd {
    ping {
      return [::coco_capture_utils::json_success [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "ping"] [::coco_capture_utils::json_field_string message "pong"]]]]
    }
    highlight_net {
      set net [string trim $arg]
      if {$net eq ""} {
        error [::coco_capture_utils::json_error "invalid_arg" "net is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "highlight_net"]]]]
      }
      return [highlight_net $net]
    }
    highlight_part {
      set part [string trim $arg]
      if {$part eq ""} {
        error [::coco_capture_utils::json_error "invalid_arg" "refdes is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "highlight_part"]]]]
      }
      return [highlight_part $part]
    }
    clear_highlight -
    clear -
    clear_selection -
    unhighlight {
      return [clear_highlight]
    }
    list_part_properties -
    part_properties {
      set part [string trim $arg]
      if {$part eq ""} {
        error [::coco_capture_utils::json_error "invalid_arg" "refdes is required" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command "part_properties"]]]]
      }
      return [list_part_properties $part]
    }
    part_property_get {
      return [part_property_get $arg]
    }
    part_property_set {
      return [part_property_set $arg]
    }
    part_property_delete {
      return [part_property_delete $arg]
    }
    part_property_display_mode {
      return [part_property_display_mode $arg]
    }
    part_move_absolute {
      return [part_move_absolute $arg]
    }
    part_move_relative {
      return [part_move_relative $arg]
    }
    rename_net {
      return [rename_net $arg]
    }
    auto_arrange_text {
      return [auto_arrange_text [string trim $arg]]
    }
    zoom_selection {
      return [zoom_selection]
    }
    zoom_fit {
      return [zoom_fit]
    }
    find_text {
      return [find_text [string trim $arg]]
    }
    list_ports {
      return [list_ports $arg]
    }
    list_offpage_connectors {
      return [list_offpage_connectors $arg]
    }
    get_text_objects {
      return [get_text_objects $arg]
    }
    find_replace {
      return [find_replace $arg]
    }

    default {
      error [::coco_capture_utils::json_error "unknown_command" "Unknown command '$cmd'" [::coco_capture_utils::json_object_from_pairs [list [::coco_capture_utils::json_field_string command $cmd]]]]
    }
  }
}

proc ::coco_capture_bridge::on_readable {chan} {
  variable token

  if {[eof $chan]} {
    catch {close $chan}
    return
  }

  set n [gets $chan line]
  if {$n < 0} {
    return
  }

  set fields [split $line "\t"]
  if {[llength $fields] < 4} {
    send_response $chan "" [::coco_capture_utils::json_error "malformed_request" "Malformed request"]
    return
  }

  set id [lindex $fields 0]
  set cmd [lindex $fields 1]
  set arg [lindex $fields 2]
  set req_token [lindex $fields 3]

  if {$token ne "" && $req_token ne $token} {
    send_response $chan $id [::coco_capture_utils::json_error "auth_failed" "AUTH_FAILED"]
    return
  }

  if {[catch {set out [dispatch $cmd $arg]} err]} {
    send_response $chan $id [::coco_capture_utils::ensure_error_json $err]
    return
  }

  send_response $chan $id $out
}

proc ::coco_capture_bridge::on_accept {chan addr remote_port} {
  fconfigure $chan -encoding utf-8 -translation lf -buffering line -blocking 0
  fileevent $chan readable [list ::coco_capture_bridge::on_readable $chan]
}

proc ::coco_capture_bridge::start {{new_host "127.0.0.1"} {new_port 49500} {new_token ""}} {
  variable host
  variable port
  variable token
  variable server_sock

  # Load optional implementation hooks (if present) before serving requests.
  catch {load_default_impl}

  if {$server_sock ne ""} {
    catch {close $server_sock}
    set server_sock ""
  }

  set host $new_host
  set port $new_port

  if {$new_token ne ""} {
    set token $new_token
  } elseif {[info exists ::env(COCO_CAPTURE_BRIDGE_TOKEN)]} {
    set token $::env(COCO_CAPTURE_BRIDGE_TOKEN)
  } else {
    set token ""
  }

  set server_sock [socket -server [list ::coco_capture_bridge::on_accept] -myaddr $host $port]
  return "coco_capture_bridge started on ${host}:${port}"
}

proc ::coco_capture_bridge::stop {} {
  variable server_sock
  if {$server_sock ne ""} {
    catch {close $server_sock}
    set server_sock ""
  }
  return "coco_capture_bridge stopped"
}

if {![info exists ::env(COCO_CAPTURE_BRIDGE_DISABLE_AUTO_START)]} {
  catch {::coco_capture_bridge::load_default_impl}
  catch {::coco_capture_bridge::start}
}
