import gdb, json
out=open('probe.events.log','w',buffering=1)
active=False
seq=0
def emit(event,**values):
    out.write(json.dumps(dict(event=event,**values),sort_keys=True)+'\n')
def val(expr):return gdb.parse_and_eval(expr)
def rec(expr):
    r=val(expr); length=int(r['length']); data=bytes(gdb.selected_inferior().read_memory(r['data'],max(0,length)))
    return dict(length=length,area_size=int(r['area_size']),type=int(r['type']),header_hex=data[:32].hex())
class Done(gdb.FinishBreakpoint):
    def __init__(self,event,extra=None):
        self.event=event;self.extra=extra or {};super().__init__(internal=True)
    def stop(self):
        emit(self.event,result=str(self.return_value),**self.extra);return False
class Probe(gdb.Breakpoint):
    def __init__(self,spec,event):
        self.event=event;super().__init__(spec,internal=False)
    def stop(self):
        global active,seq
        try:
            if self.event=='disk_update':
                active=True;emit(self.event,oid=str(val('*oid')));Done('disk_update_return')
            elif self.event=='serialize' and active:
                r=val('record');emit('serialize_enter',area_size=int(r['area_size']))
                class Serialized(Done):
                    def stop(self):
                        global seq
                        length=int(r['length']); emit('serialize_return',result=str(self.return_value),record=recptr(r))
                        if length>0:
                            seq+=1;open('serialized-%d.hex.log'%seq,'w').write(bytes(gdb.selected_inferior().read_memory(r['data'],length)).hex()+'\n')
                        return False
                Serialized('serialize_return')
            elif self.event=='heap_update' and active:
                emit(self.event,record=rec('context->recdes_p'),max_slotted=int(val('heap_Maxslotted_reclength')));Done('heap_update_return')
            elif self.event=='overflow' and active:
                vpid=val('ovf_vpid'); emit(self.event,record=rec('recdes'),file_type=str(val('file_type')),vfid=str(val('*ovf_vfid')),stack=gdb.execute('bt 8',to_string=True))
                class OverflowDone(Done):
                    def stop(self):
                        emit('overflow_return',result=str(self.return_value),vpid=str(vpid.dereference()));return False
                OverflowDone('overflow_return')
            elif self.event=='forward' and active:
                emit(self.event,record_type=str(val('rec_type')),oid=str(val('*forward_oid')))
            elif self.event=='planner' and active:emit(self.event)
        except Exception as e:emit('probe_error',probe=self.event,error=str(e))
        return False
def recptr(r):
    n=int(r['length']);data=bytes(gdb.selected_inferior().read_memory(r['data'],max(0,n)))
    return dict(length=n,area_size=int(r['area_size']),type=int(r['type']),header_hex=data[:32].hex())
for spec,event in [('disk_update_instance','disk_update'),('desc_obj_to_disk','serialize'),('heap_update_logical','heap_update'),('overflow_insert','overflow'),('heap_build_forwarding_recdes','forward'),('heap_attrinfo_determine_disk_layout','planner')]:Probe(spec,event)
