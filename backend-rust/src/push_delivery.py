"""Process one due notification using an independent SQLite connection."""
import json
import secrets
import sqlite3
import time

TERMINAL = ('cancelled','uncertain','failed','partial','delivered','no_devices')

def process(path, push, unseal, now=time.time):
    db=sqlite3.connect(path,timeout=10,isolation_level=None)
    db.execute('PRAGMA foreign_keys=ON')
    try:
        return _process(db,push,unseal,now)
    finally:
        db.close()

def _process(db,push,unseal,clock):
    db.execute('BEGIN IMMEDIATE')
    now=clock()
    row=db.execute("""SELECT id,owner,run_id,state,deliveries,initialized,receipt FROM push_notifications
                      WHERE due<=? ORDER BY due,rowid LIMIT 1""",(now,)).fetchone()
    if not row:
        db.rollback()
        return False
    id,owner,run,state,raw,initialized,receipt=row
    items=json.loads(raw)
    def save():
        status=push.status(items)
        deadlines=[d['lease_until'] if d['lease'] else d['due_at'] for d in items if d['state'] in ('claimed','dispatching','queued','accepted')]
        due=min(deadlines,default=None)
        db.execute('UPDATE push_notifications SET state=?,deliveries=?,initialized=1,due=? WHERE owner=? AND id=?',
                   (status,json.dumps(items),due,owner,id))
        db.commit()
    if state in TERMINAL:
        db.execute('UPDATE push_notifications SET due=NULL WHERE id=?',(id,))
        db.commit()
        return True
    if not initialized:
        if state=='queued':
            items=[push.new_delivery(key) for (key,) in db.execute('SELECT key FROM push_devices WHERE owner=?',(owner,))]
        elif state=='sent' and receipt:
            for index,ticket in enumerate(receipt.split(',')):
                d=push.new_delivery('legacy:'+str(index))
                d.update(state='accepted',ticket=ticket,accepted_at=now,due_at=now)
                items.append(d)
        else:
            db.execute("UPDATE push_notifications SET due=NULL,state='uncertain',initialized=1 WHERE id=?",(id,))
            db.commit()
            return True
    items=push.recover(items,now)
    for d in items:
        if d['lease'] or d['due_at']>now or d['state'] not in ('queued','accepted'):
            continue
        send=d['state']=='queued'
        if send:
            device=db.execute('SELECT sealed FROM push_devices WHERE owner=? AND key=?',(owner,d['key'])).fetchone()
            if not device:
                d.update(state='failed',error='DeviceRemoved')
                continue
            try:
                token=unseal(device[0])['token']
            except (ValueError,KeyError):
                d.update(state='failed',error='DeviceLocked')
                continue
            d.update(state='dispatching',attempts=d['attempts']+1)
        else:
            d['receipt_attempts']+=1
        lease=secrets.token_urlsafe(24)
        d.update(lease=lease,lease_until=now+push.LEASE_SECONDS)
        save()
        result=push.deliver(token,{'owner':owner,'run_id':run}) if send else push.receipt(d['ticket'])
        db.execute('BEGIN IMMEDIATE')
        fresh=db.execute('SELECT deliveries,state FROM push_notifications WHERE owner=? AND id=?',(owner,id)).fetchone()
        if not fresh or fresh[1]=='cancelled':
            db.rollback()
            return True
        items=json.loads(fresh[0])
        for index,active in enumerate(items):
            if active['lease']==lease and active['lease_until']>clock():
                updated=push.complete(active,result,clock())
                if updated['error']=='DeviceNotRegistered':
                    db.execute('DELETE FROM push_devices WHERE owner=? AND key=?',(owner,active['key']))
                items[index]=updated
                break
        save()
        return True
    save()
    return True
