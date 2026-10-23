"""Process-local write turns, split by what they protect (issue #108).

Data correctness never depends on these locks: every write runs in a SERIALIZABLE
transaction and the runtime re-runs a request on a serialization conflict. The
locks only order work inside this process so that read-modify-write sequences
(revision checks, client_id de-duplication, leases) rarely conflict, and so
unrelated work never waits in one line.

    sweep()        background loops over every account (agent, resume and notification
                   claims, the daily feed refresh, schedules). User requests never take it.
    account(id)    one per account: that account's own writes, including worker calls
                   acting for it. Accounts never wait on each other.
    collector()    job collection only (discovery claim, complete, manage, analyze).
                   It is never shared with account, agent or sweep work.
    cache()        the in-memory catalog view. Innermost: hold it only for short reads
                   and swaps, and take no other lock while holding it.

Acquisition order is sweep -> account -> cache, and collector -> cache. No account
or sweep path takes collector(), and nothing takes sweep() or account() while
holding cache(). Keep this order so the locks cannot deadlock.

These are threading locks, so they order work only within one API process. Running
several workers (#110) needs cross-process locks; see #108 for the plan."""
import from threading { Lock, RLock }

glob _sweep: RLock = RLock();
glob _collector: RLock = RLock();
glob _cache: RLock = RLock();
glob _registry: Lock = Lock();
glob _accounts: dict[str, RLock] = {};

def sweep -> RLock { return _sweep; }
def collector -> RLock { return _collector; }
def cache -> RLock { return _cache; }

"""The write turn for one account; the caller's own account when owner is empty."""
def account(owner: str = "") -> RLock {
    key = owner or jid(root);
    with _registry {
        turn = _accounts.get(key);
        if turn is None { turn = RLock(); _accounts[key] = turn; }
        return turn;
    }
}
