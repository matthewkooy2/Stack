import Foundation
import Observation
import UIKit
import UserNotifications

/// The signed-in account and the actions that change it. Every mutation returns a fresh snapshot,
/// which replaces `account`, so views only ever render what the server last confirmed.
@MainActor
@Observable
final class AppStore {
    enum Phase { case starting, signedOut, admission, ready }

    let api: APIClient
    let prep: PrepTransport
    let google: GoogleSignIn

    var phase: Phase = .starting
    var account = AccountState()
    var busy = false
    var error = ""
    var notice = ""
    /// `auth_google_status`: username, whether Google is linked, and whether recovery is possible.
    var googleInfo: JSON = [:]
    var googlePending = false
    var pendingInvite = ""
    /// A record a tapped notification asked to open; the owning tab consumes it.
    var pendingOpen: [String: String] = [:]
    /// Overridable so tests can drive the Google handoff without UIKit.
    var openExternalURL: (URL) async -> Bool = { await UIApplication.shared.open($0) }
    var isForeground: () -> Bool = { UIApplication.shared.applicationState == .active }

    private var refreshing = false
    private var epoch = 0
    private(set) var sessionGeneration = 0
    private var swipeChain: Task<Void, Never>?
    private var pendingSwipes = 0

    init(api: APIClient = APIClient(origin: APIClient.configuredOrigin)) {
        self.api = api
        self.prep = PrepTransport(api: api)
        self.google = GoogleSignIn(api: api)
    }

    // MARK: Session

    func start() async {
        if let handoff = google.pending() {
            await finishGoogle(handoff)
            return
        }
        guard api.hasSession else { phase = .signedOut; return }
        await completeLogin()
    }

    func signIn(username: String, password: String, signUp: Bool, invite: String = "") async {
        guard !busy, !googlePending else { return }
        guard username.trimmingCharacters(in: .whitespaces).count >= 3, password.count >= 8 else {
            error = "Use a username of at least 3 characters and a password of at least 8."
            return
        }
        busy = true
        error = ""
        defer { busy = false }
        do {
            try await api.authenticate(username: username, password: password, signUp: signUp)
            pendingInvite = invite.trimmingCharacters(in: .whitespaces)
            await completeLogin()
        } catch { fail(error) }
    }

    func acceptInvitation(_ code: String) async {
        guard !busy else { return }
        let generation = sessionGeneration
        busy = true
        error = ""
        defer { if generation == sessionGeneration { busy = false } }
        do {
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { try await api.call("agent_accept_invite", ["invite": .string(trimmed)]) }
            guard generation == sessionGeneration else { return }
            await completeLogin()
        } catch { fail(error) }
    }

    private func completeLogin() async {
        let generation = sessionGeneration
        do {
            do { googleInfo = try await api.call("auth_google_status") }
            catch let failure as APIError where failure.status == 404 { googleInfo = [:] }
            if !pendingInvite.isEmpty {
                let invite = pendingInvite
                pendingInvite = ""
                try await api.call("agent_accept_invite", ["invite": .string(invite)])
            }
            let admission = try await api.call("agent_admission")
            guard generation == sessionGeneration else { return }
            guard admission["admitted"].bool else {
                phase = .admission
                return
            }
            let snapshot = try await api.call("bootstrap")
            guard generation == sessionGeneration else { return }
            account = AccountState(raw: snapshot)
            phase = .ready
            await reconcileReminders(ask: false)
        } catch let failure as APIError where failure.isUnauthorized && generation == sessionGeneration {
            await signOut()
            error = "Your session expired. Please sign in again."
        } catch is CancellationError {
        } catch {
            guard generation == sessionGeneration else { return }
            fail(error)
            if phase == .starting { phase = .signedOut }
        }
    }

    func signOut() async {
        epoch += 1
        sessionGeneration += 1
        swipeChain?.cancel()
        swipeChain = nil
        pendingSwipes = 0
        busy = false
        google.cancel()
        googlePending = false
        googleInfo = [:]
        pendingInvite = ""
        pendingOpen = [:]
        AgentDrafts.removeAll()
        if phase == .ready {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        }
        RecordingStore.removeAll()
        api.forget()
        prep.resetCatalog()
        account = AccountState()
        error = ""
        notice = ""
        phase = .signedOut
    }

    // MARK: Data

    /// Quietly re-reads the account; used on foreground and on a timer.
    func refresh() async {
        guard phase == .ready, !busy, !refreshing, pendingSwipes == 0 else { return }
        refreshing = true
        let observed = epoch
        let generation = sessionGeneration
        defer { refreshing = false }
        do {
            let latest = try await api.call("bootstrap")
            if observed == epoch, !busy { account = AccountState(raw: latest) }
            await reconcileReminders(ask: false)
        } catch let failure as APIError where failure.isUnauthorized && generation == sessionGeneration {
            await signOut()
            error = "Your session expired. Please sign in again."
        } catch {}
    }

    /// Calls an endpoint that answers with a new account snapshot.
    @discardableResult
    func mutate(_ endpoint: String, _ args: JSON, notice message: String = "Saved to your Stack.", askNotifications: Bool = false, timeout: TimeInterval = 25) async -> Bool {
        guard phase == .ready, !busy, pendingSwipes == 0 else { return false }
        let generation = sessionGeneration
        busy = true
        error = ""
        notice = ""
        epoch += 1
        defer { if generation == sessionGeneration { busy = false } }
        do {
            let snapshot = try await api.call(endpoint, args, timeout: timeout)
            guard generation == sessionGeneration, phase == .ready else { return false }
            account = AccountState(raw: snapshot)
            notice = message
            await reconcileReminders(ask: askNotifications)
            return true
        } catch let failure as APIError where failure.isUnauthorized && generation == sessionGeneration {
            await signOut()
            error = "Your session expired. Please sign in again."
        } catch { if generation == sessionGeneration { fail(error) } }
        return false
    }

    /// Saves (`apply`) or passes a job. Swipes run one after another so quick successive swipes all land.
    func swipe(jobID: String, save: Bool) async -> Bool {
        guard phase == .ready, !busy else { return false }
        let generation = sessionGeneration
        let previous = swipeChain
        pendingSwipes += 1
        epoch += 1
        let task = Task { [self] () -> Bool in
            await previous?.value
            guard generation == sessionGeneration, phase == .ready, !Task.isCancelled else { return false }
            defer { if generation == sessionGeneration { pendingSwipes -= 1 } }
            do {
                let snapshot = try await api.call("swipe", ["job_id": .string(jobID), "action": save ? "apply" : "pass"])
                guard generation == sessionGeneration, phase == .ready, !Task.isCancelled else { return false }
                account = AccountState(raw: snapshot)
                return true
            } catch {
                if generation == sessionGeneration { fail(error) }
                return false
            }
        }
        swipeChain = Task { _ = await task.value }
        return await task.value
    }

    // MARK: Google

    /// Signs in with Google, or links Google to the signed-in account when `link` is true.
    func signInWithGoogle(link: Bool = false, invite: String = "") async {
        guard !googlePending, !busy else { return }
        if link { guard phase == .ready || phase == .admission else { return } }
        googlePending = true
        error = ""
        notice = ""
        do {
            let handoff = try await google.begin(invite: invite.trimmingCharacters(in: .whitespaces), link: link, open: openExternalURL)
            await finishGoogle(handoff)
        } catch {
            googlePending = false
            fail(error)
        }
    }

    private func finishGoogle(_ handoff: GoogleHandoff) async {
        googlePending = true
        defer { googlePending = false }
        do {
            let token = try await google.wait(for: handoff, isActive: isForeground)
            guard !Task.isCancelled else { return }
            api.adopt(token: token)
            sessionGeneration += 1
            pendingInvite = handoff.invite
            await completeLogin()
            if handoff.link, phase == .ready { notice = "Google sign-in is linked to this Stack account." }
        } catch is CancellationError {
            if phase == .starting { phase = api.hasSession ? .starting : .signedOut }
        } catch {
            fail(error)
            if phase == .starting { phase = api.hasSession ? .starting : .signedOut }
            if phase == .starting { await completeLogin() }
        }
    }

    func cancelGoogle() {
        google.cancel()
        googlePending = false
        if phase == .starting { phase = api.hasSession ? .starting : .signedOut }
    }

    /// Links Google to the original Stack account by confirming its credentials.
    func recoverGoogle(username: String, password: String) async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let result = try await api.call("auth_google_recover", ["username": .string(username), "password": .string(password)])
            guard !result["token"].string.isEmpty else { throw APIError(message: "Sign-in did not return a session.") }
            api.adopt(token: result["token"].string)
            sessionGeneration += 1
            phase = .starting
            await completeLogin()
            if phase == .ready { notice = "Google is linked to your original account." }
        } catch { fail(error) }
    }

    // MARK: Requests

    /// A personal API call that is dropped (throws `CancellationError`) when the account changed while
    /// it ran, and signs out on an expired session.
    @discardableResult
    func call(_ name: String, _ args: JSON = [:], timeout: TimeInterval = 25) async throws -> JSON {
        guard phase == .ready || phase == .admission else { throw CancellationError() }
        let generation = sessionGeneration
        do {
            let result = try await api.call(name, args, timeout: timeout)
            guard generation == sessionGeneration, phase == .ready || phase == .admission else { throw CancellationError() }
            return result
        } catch let failure as APIError where failure.isUnauthorized && generation == sessionGeneration {
            await signOut()
            error = "Your session expired. Please sign in again."
            throw CancellationError()
        }
    }

    /// Like `call`, but returns the new account snapshot and stores it.
    @discardableResult
    func callAccount(_ name: String, _ args: JSON = [:], timeout: TimeInterval = 25) async throws -> JSON {
        guard phase == .ready else { throw CancellationError() }
        guard !busy, pendingSwipes == 0 else {
            throw APIError(message: "Wait for the current change to finish, then try again.")
        }
        let generation = sessionGeneration
        busy = true
        epoch += 1
        defer { if generation == sessionGeneration { busy = false } }
        let result = try await call(name, args, timeout: timeout)
        guard generation == sessionGeneration, phase == .ready else { throw CancellationError() }
        account = AccountState(raw: result)
        await reconcileReminders(ask: false)
        return result
    }

    func fail(_ failure: Error) {
        if failure is CancellationError { return }
        error = failure.localizedDescription
    }

    // MARK: Reminders

    /// Schedules a local alert for each open reminder.
    func reconcileReminders(ask: Bool) async {
        let generation = sessionGeneration
        guard account.notificationsOn || ask else {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            return
        }
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        guard generation == sessionGeneration, phase == .ready else { return }
        if ask, settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
            guard generation == sessionGeneration, phase == .ready else { return }
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            if ask { notice = "Reminder saved. Enable notifications in iPhone Settings to receive alerts." }
            return
        }
        center.removeAllPendingNotificationRequests()
        let now = Date().timeIntervalSince1970
        for reminder in account.reminders where !reminder.done && reminder.dueAt > now {
            let content = UNMutableNotificationContent()
            content.title = "Stack · Follow up"
            content.body = reminder.title
            content.userInfo = ["target_type": reminder.targetType, "target_id": reminder.targetID, "user_id": account.userID]
            let interval = max(1, reminder.dueAt - now)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: "stack-\(account.userID)-\(reminder.id)", content: content, trigger: trigger)
            try? await center.add(request)
            if generation != sessionGeneration {
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                return
            }
        }
    }
}
