# coco-connect-capture list_offpage_connectors bridge implementation (M2).
#
# Enumerates off-page connectors with name + absolute coordinates, sorted by
# (x, y). JSON-array replacement for the benchmark's copy_offpage.tcl. Read-only.
#
# Off-page connectors share the exact enumeration shape of ports (same name
# getter, coordinate math, and sort), so this delegates to the generic core in
# list_ports.tcl (::list_objects::collect), differing only in the page iterator
# (NewOffPageConnectorsIter / NextOffPageConnector). Direction is NOT listed here
# (the benchmark's copy_offpage.tcl doesn't either); it belongs to the separate
# change_offpage_direction tool. scope: active_page (default) | all.

# Impl entry: arg = scope (active_page default | all)
proc ::coco_capture_list_offpage_connectors_impl {arg} {
    return [::list_objects::collect "list_offpage_connectors" [::list_objects::_scope_arg $arg] \
        NewOffPageConnectorsIter NextOffPageConnector delete_DboPageOffPageConnectorsIter \
        connector_count connectors]
}
