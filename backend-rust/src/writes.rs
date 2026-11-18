use crate::{RequestData, Response, rpc, rpc_inner, should_commit};
use rusqlite::{Connection, Result, TransactionBehavior};
use std::{io, sync::mpsc, thread};
use tokio::sync::oneshot;

type Reply = oneshot::Sender<Option<Response>>;
type Work = (RequestData, Reply);

pub struct Writer(mpsc::SyncSender<Work>);

impl Writer {
    pub fn start(mut db: Connection) -> io::Result<Self> {
        let (sender, receiver) = mpsc::sync_channel::<Work>(64);
        thread::Builder::new()
            .name("stack-writer".into())
            .spawn(move || {
                while let Ok(first) = receiver.recv() {
                    // Only group requests already waiting. A solitary writer never waits for a batch.
                    let Ok(second) = receiver.try_recv() else {
                        let (req, reply) = first;
                        let response = rpc(
                            &mut db,
                            req.path.trim_start_matches("/function/"),
                            &req.token,
                            &req.args,
                        );
                        let _ = reply.send(response.ok());
                        continue;
                    };
                    let work = [first, second]
                        .into_iter()
                        .chain(receiver.try_iter().take(6));
                    let mut batch: Vec<_> = work.map(|(req, reply)| (req, reply, None)).collect();
                    let committed = commit_group(&mut db, &mut batch).is_ok();
                    for (_, reply, response) in batch {
                        let _ = reply.send(if committed { response } else { None });
                    }
                }
            })?;
        Ok(Self(sender))
    }

    pub async fn execute(&self, request: RequestData) -> Option<Response> {
        let (reply, result) = oneshot::channel();
        self.0.try_send((request, reply)).ok()?;
        result.await.ok().flatten()
    }
}

fn commit_group(
    db: &mut Connection,
    batch: &mut [(RequestData, Reply, Option<Response>)],
) -> Result<()> {
    let mut tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    for (request, _, response) in batch {
        let save = tx.savepoint()?;
        let name = request.path.trim_start_matches("/function/");
        match rpc_inner(&save, name, &request.token, &request.args) {
            Ok(result) if should_commit(&result) => {
                save.commit()?;
                *response = Some(result);
            }
            outcome => {
                // Explicitly roll back and release. Never allow a rollback failure to
                // be swallowed by Drop and let another request commit partial changes.
                save.finish()?;
                *response = outcome.ok();
            }
        }
    }
    tx.commit()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{auth, open};
    use serde_json::json;

    #[test]
    fn a_failed_mutation_restores_its_invite_before_committing_the_next_writer() {
        let mut db = open(":memory:").unwrap();
        auth::init(&db).unwrap();
        db.execute_batch("INSERT INTO accounts(id,username,password) VALUES ('a','alpha','unused'),('b','beta','unused');
            CREATE TRIGGER fail_a BEFORE UPDATE ON accounts WHEN OLD.id='a'
            BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;").unwrap();
        let invite = auth::new_invite(&db).unwrap();
        let mut batch = ["a", "b"].map(|owner| {
            (
                RequestData {
                    path: "/function/agent_accept_invite".into(),
                    token: auth::issue(&db, owner).unwrap(),
                    args: json!({"invite":invite}),
                },
                oneshot::channel().0,
                None,
            )
        });
        commit_group(&mut db, &mut batch).unwrap();
        assert!(batch[0].2.is_none());
        assert_eq!(
            batch[1].2.as_ref().unwrap().1["data"]["result"]["admitted"],
            true
        );
        assert_eq!(
            db.query_row(
                "SELECT COUNT(*) FROM accounts WHERE invited=1 AND id='b'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );
    }

    #[test]
    fn a_deferred_commit_failure_rolls_back_every_writer() {
        let mut db = open(":memory:").unwrap();
        auth::init(&db).unwrap();
        db.execute_batch("INSERT INTO accounts(id,username,password) VALUES ('a','alpha','unused'),('b','beta','unused');
            CREATE TABLE deferred_errors(id TEXT REFERENCES accounts(id) DEFERRABLE INITIALLY DEFERRED);
            CREATE TRIGGER fail_commit AFTER UPDATE ON accounts WHEN OLD.id='b'
            BEGIN INSERT INTO deferred_errors VALUES ('missing'); END;").unwrap();
        let mut batch = ["a", "b"].map(|owner| {
            let invite = auth::new_invite(&db).unwrap();
            (
                RequestData {
                    path: "/function/agent_accept_invite".into(),
                    token: auth::issue(&db, owner).unwrap(),
                    args: json!({"invite":invite}),
                },
                oneshot::channel().0,
                None,
            )
        });
        assert!(commit_group(&mut db, &mut batch).is_err());
        assert_eq!(
            db.query_row("SELECT SUM(invited) FROM accounts", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM invites", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            2
        );
    }
}
