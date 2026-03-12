# coco_capture_bootstrap.tcl
#
# Minimal Capture-side Tcl bridge for coco-connect-capture.
# Line protocol (UTF-8):
#   request:  id<TAB>cmd<TAB>arg<TAB>token\n
#   response: id<TAB>ok|err<TAB>message\n

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
  set impl_file [file join $dir highlight.tcl]

  if {![file exists $impl_file]} {
    return 0
  }

  source_utf8 $impl_file
  set impl_loaded 1
  return 1
}

proc ::coco_capture_bridge::send_response {chan id status message} {
  set safe_id [sanitize_field $id]
  set safe_status [sanitize_field $status]
  set safe_message [sanitize_field $message]

  catch {
    puts $chan "${safe_id}\t${safe_status}\t${safe_message}"
    flush $chan
  }
  catch {close $chan}
}

proc ::coco_capture_bridge::highlight_net {net} {
  if {[llength [info commands ::coco_capture_highlight_net_impl]] > 0} {
    return [::coco_capture_highlight_net_impl $net]
  }

  error "No net-highlight implementation found. Define ::coco_capture_highlight_net_impl net"
}

proc ::coco_capture_bridge::highlight_part {part} {
  if {[llength [info commands ::coco_capture_highlight_part_impl]] > 0} {
    return [::coco_capture_highlight_part_impl $part]
  }

  error "No part-highlight implementation found. Define ::coco_capture_highlight_part_impl part"
}

proc ::coco_capture_bridge::clear_highlight {} {
  if {[llength [info commands ::coco_capture_clear_highlight_impl]] > 0} {
    return [::coco_capture_clear_highlight_impl]
  }

  error "No clear-highlight implementation found. Define ::coco_capture_clear_highlight_impl"
}

proc ::coco_capture_bridge::dispatch {cmd arg} {
  switch -- $cmd {
    ping {
      return "pong"
    }
    highlight_net {
      set net [string trim $arg]
      if {$net eq ""} {
        error "net is required"
      }
      return [highlight_net $net]
    }
    highlight_part {
      set part [string trim $arg]
      if {$part eq ""} {
        error "part is required"
      }
      return [highlight_part $part]
    }
    clear_highlight -
    clear -
    clear_selection -
    unhighlight {
      return [clear_highlight]
    }
    default {
      error "Unknown command '$cmd'"
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
    send_response $chan "" "err" "Malformed request"
    return
  }

  set id [lindex $fields 0]
  set cmd [lindex $fields 1]
  set arg [lindex $fields 2]
  set req_token [lindex $fields 3]

  if {$token ne "" && $req_token ne $token} {
    send_response $chan $id "err" "AUTH_FAILED"
    return
  }

  if {[catch {set out [dispatch $cmd $arg]} err]} {
    send_response $chan $id "err" $err
    return
  }

  send_response $chan $id "ok" $out
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
