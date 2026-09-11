import Foundation

/// Coordinates one provider-owned login attempt. All installation, launch,
/// identity, quota, and model operations are injected through
/// `LocalCLILoginCapability`; this type does not inspect credentials or start
/// a process itself.
actor LocalCLILoginCoordinator {
    private struct ActiveAttempt {
        let id: UUID
        let target: LocalCLILoginTarget
        let capability: any LocalCLILoginCapability
        var workflow: LocalCLILoginWorkflow
        var receipt: LocalCLILoginLaunchReceipt?
    }

    private let capabilities: [LocalCLILoginProvider: any LocalCLILoginCapability]
    private var activeAttempt: ActiveAttempt?
    private var pendingCancellations: Set<UUID> = []
    private var driverTask: Task<Void, Never>?
    private(set) var status: LocalCLILoginStatus = .empty

    init(capability: any LocalCLILoginCapability) {
        self.capabilities = [capability.descriptor.provider: capability]
    }

    init(capabilities: [LocalCLILoginProvider: any LocalCLILoginCapability]) {
        self.capabilities = capabilities
    }

    func descriptor(for provider: LocalCLILoginProvider) -> LocalCLILoginCapabilityDescriptor? {
        capabilities[provider]?.descriptor
    }

    var isActive: Bool { activeAttempt != nil }

    /// Starts detection and, if needed, the provider's official authorization
    /// entry point. A repeated call while an attempt is active returns nil and
    /// never calls the injected launcher a second time.
    @discardableResult
    func start(
        target: LocalCLILoginTarget,
        expectedIdentity: LocalCLILoginIdentity? = nil,
        models: [String] = []
    ) -> UUID? {
        guard activeAttempt == nil else { return nil }

        let attemptID = UUID()
        var workflow = LocalCLILoginWorkflow(
            target: target,
            attemptID: attemptID,
            expectedIdentity: expectedIdentity,
            targetModels: models)

        guard !target.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let capability = capabilities[target.provider],
            capability.descriptor.provider == target.provider
        else {
            _ = workflow.markFailed(.unsupported)
            status = workflow.status
            return attemptID
        }

        activeAttempt = ActiveAttempt(
            id: attemptID,
            target: target,
            capability: capability,
            workflow: workflow,
            receipt: nil)
        status = workflow.status

        driverTask = Task { [weak self] in
            await self?.runDetection(attemptID: attemptID, target: target, capability: capability)
        }
        return attemptID
    }

    /// Marks the attempt cancelled before awaiting the injected cancel hook.
    /// Any callback for this UUID is ignored, including callbacks arriving
    /// after a new attempt has started.
    @discardableResult
    func cancel(attemptID: UUID? = nil) async -> Bool {
        guard let current = activeAttempt,
            attemptID == nil || attemptID == current.id
        else { return false }

        var cancelled = current.workflow
        guard cancelled.markCancelled() else { return false }
        status = cancelled.status
        activeAttempt = nil
        driverTask?.cancel()
        driverTask = nil

        if let receipt = current.receipt {
            await current.capability.cancelAuthorization(target: current.target, receipt: receipt)
        } else if current.workflow.status.state == .needsAuthorization {
            // The launch call may already be in flight. If it eventually
            // returns a receipt, launchAuthorization cancels that exact receipt.
            pendingCancellations.insert(current.id)
        }
        return true
    }

    /// Delivers the provider's return/exit event. A zero exit code only moves
    /// the workflow to identity verification; it can never make it ready.
    @discardableResult
    func authorizationDidReturn(
        attemptID: UUID,
        receiptID: UUID? = nil,
        exitCode: Int32 = 0
    ) -> Bool {
        guard var current = activeAttempt,
            current.id == attemptID,
            current.workflow.status.state == .waitingForReturn,
            receiptID == nil || receiptID == current.receipt?.id
        else { return false }

        guard exitCode == 0 else {
            _ = current.workflow.markFailed(.authorizationFailed)
            status = current.workflow.status
            activeAttempt = nil
            driverTask = nil
            return true
        }

        guard current.workflow.markVerifyingIdentity() else { return false }
        activeAttempt = current
        status = current.workflow.status
        let capability = current.capability
        let target = current.target
        driverTask = Task { [weak self] in
            await self?.verifyIdentityAfterAuthorization(
                attemptID: attemptID,
                target: target,
                capability: capability)
        }
        return true
    }

    /// The normal path never invokes advanced association automatically. This
    /// method exists as a parent-wiring seam for an explicit fallback action.
    func fallbackAssociation(target: LocalCLILoginTarget) async -> LocalCLILoginIdentityEvidence {
        guard let capability = capabilities[target.provider] else { return .unsupported }
        return await capability.fallbackAssociation(target: target)
    }

    func snapshot() -> LocalCLILoginStatus { status }

    private func runDetection(
        attemptID: UUID,
        target: LocalCLILoginTarget,
        capability: any LocalCLILoginCapability
    ) async {
        guard activeAttempt?.id == attemptID else {
            pendingCancellations.remove(attemptID)
            return
        }

        let detection = await capability.detect(target: target)
        guard activeAttempt?.id == attemptID else {
            pendingCancellations.remove(attemptID)
            return
        }
        guard detection.installed else {
            failActive(attemptID: attemptID, reason: .notInstalled)
            return
        }

        let identity = await capability.discoverIdentity(target: target)
        guard activeAttempt?.id == attemptID else {
            pendingCancellations.remove(attemptID)
            return
        }

        switch identity {
        case .verified:
            guard var current = activeAttempt,
                current.workflow.markVerifyingIdentity()
            else {
                failActive(attemptID: attemptID, reason: .identityUnverified)
                return
            }
            activeAttempt = current
            status = current.workflow.status
            await advanceIdentity(
                attemptID: attemptID,
                evidence: identity,
                target: target,
                capability: capability)

        case .missing:
            guard capability.descriptor.supportsAuthorization else {
                failActive(attemptID: attemptID, reason: .unsupported)
                return
            }
            guard var current = activeAttempt,
                current.workflow.markNeedsAuthorization()
            else { return }
            activeAttempt = current
            status = current.workflow.status
            await launchAuthorization(
                attemptID: attemptID,
                target: target,
                capability: capability)

        case .unverified:
            failActive(attemptID: attemptID, reason: .identityUnverified)
        case .unsupported:
            failActive(attemptID: attemptID, reason: .unsupported)
        }
    }

    private func launchAuthorization(
        attemptID: UUID,
        target: LocalCLILoginTarget,
        capability: any LocalCLILoginCapability
    ) async {
        guard activeAttempt?.id == attemptID else {
            pendingCancellations.remove(attemptID)
            return
        }

        do {
            let receipt = try await capability.startAuthorization(target: target)
            guard var current = activeAttempt, current.id == attemptID else {
                if pendingCancellations.remove(attemptID) != nil {
                    await capability.cancelAuthorization(target: target, receipt: receipt)
                }
                return
            }
            current.receipt = receipt
            guard current.workflow.markWaitingForReturn(receipt: receipt) else {
                activeAttempt = current
                failActive(attemptID: attemptID, reason: .authorizationFailed)
                return
            }
            activeAttempt = current
            status = current.workflow.status
        } catch let error as LocalCLILoginCapabilityError {
            if activeAttempt?.id != attemptID {
                pendingCancellations.remove(attemptID)
                return
            }
            failActive(
                attemptID: attemptID,
                reason: error == .unsupported ? .unsupported : .authorizationFailed)
        } catch {
            if activeAttempt?.id != attemptID {
                pendingCancellations.remove(attemptID)
                return
            }
            failActive(attemptID: attemptID, reason: .authorizationFailed)
        }
    }

    private func verifyIdentityAfterAuthorization(
        attemptID: UUID,
        target: LocalCLILoginTarget,
        capability: any LocalCLILoginCapability
    ) async {
        guard activeAttempt?.id == attemptID else { return }
        let evidence = await capability.discoverIdentity(target: target)
        guard activeAttempt?.id == attemptID else { return }
        await advanceIdentity(
            attemptID: attemptID,
            evidence: evidence,
            target: target,
            capability: capability)
    }

    private func advanceIdentity(
        attemptID: UUID,
        evidence: LocalCLILoginIdentityEvidence,
        target: LocalCLILoginTarget,
        capability: any LocalCLILoginCapability
    ) async {
        guard var current = activeAttempt,
            current.id == attemptID,
            current.workflow.status.state == .verifyingIdentity
        else { return }

        switch evidence {
        case .verified(let identity):
            guard current.workflow.accepts(identity) else {
                failActive(attemptID: attemptID, reason: .identityMismatch)
                return
            }
            guard current.workflow.recordIdentity(identity),
                current.workflow.markQuotaPending()
            else {
                failActive(attemptID: attemptID, reason: .identityUnverified)
                return
            }
            activeAttempt = current
            status = current.workflow.status
            await runQuota(attemptID: attemptID, target: target, capability: capability)
        case .missing:
            failActive(attemptID: attemptID, reason: .identityMissing)
        case .unverified:
            failActive(attemptID: attemptID, reason: .identityUnverified)
        case .unsupported:
            failActive(attemptID: attemptID, reason: .unsupported)
        }
    }

    private func runQuota(
        attemptID: UUID,
        target: LocalCLILoginTarget,
        capability: any LocalCLILoginCapability
    ) async {
        guard activeAttempt?.id == attemptID else { return }

        // Re-read identity at the quota boundary so an account switch cannot
        // reuse a result from the identity stage.
        let identityEvidence = await capability.discoverIdentity(target: target)
        guard let current = activeAttempt, current.id == attemptID else { return }
        guard case .verified(let identity) = identityEvidence,
            current.workflow.status.identityFingerprint == identity.fingerprint,
            current.workflow.accepts(identity)
        else {
            failActive(attemptID: attemptID, reason: .identityMismatch)
            return
        }

        let quota = await capability.readQuota(target: target)
        guard var latest = activeAttempt, latest.id == attemptID else { return }
        guard quota.status == .verified else {
            let reason: LocalCLILoginFailureReason
            switch quota.status {
            case .unavailable: reason = .quotaUnavailable
            case .unsupported: reason = .quotaUnsupported
            case .unverified: reason = .quotaUnverified
            case .verified: reason = .quotaUnverified
            }
            failActive(attemptID: attemptID, reason: reason)
            return
        }
        guard quota.identityFingerprint == latest.workflow.status.identityFingerprint else {
            failActive(attemptID: attemptID, reason: .identityMismatch)
            return
        }
        guard latest.workflow.recordQuota(quota), latest.workflow.markModelsPending() else {
            failActive(attemptID: attemptID, reason: .quotaUnverified)
            return
        }
        activeAttempt = latest
        status = latest.workflow.status

        if latest.workflow.targetModels.isEmpty {
            // No requested model means there is no model-availability evidence.
            // Stay pending instead of treating an empty list as proof of readiness.
            return
        }
        await runModels(attemptID: attemptID, target: target, capability: capability)
    }

    private func runModels(
        attemptID: UUID,
        target: LocalCLILoginTarget,
        capability: any LocalCLILoginCapability
    ) async {
        guard let current = activeAttempt, current.id == attemptID else { return }
        for model in current.workflow.targetModels {
            guard activeAttempt?.id == attemptID else { return }

            // Each model gets a fresh identity check and its own evidence.
            let identityEvidence = await capability.discoverIdentity(target: target)
            guard let latest = activeAttempt, latest.id == attemptID else { return }
            guard case .verified(let identity) = identityEvidence,
                latest.workflow.status.identityFingerprint == identity.fingerprint,
                latest.workflow.accepts(identity)
            else {
                failActive(attemptID: attemptID, reason: .identityMismatch, model: model)
                return
            }

            let evidence = await capability.verifyModel(target: target, model: model)
            guard var verified = activeAttempt, verified.id == attemptID else { return }
            guard evidence.model == model else {
                failActive(attemptID: attemptID, reason: .modelMismatch, model: model)
                return
            }
            guard evidence.identityFingerprint == verified.workflow.status.identityFingerprint else {
                failActive(attemptID: attemptID, reason: .identityMismatch, model: model)
                return
            }
            guard evidence.status == .verified else {
                let reason: LocalCLILoginFailureReason
                switch evidence.status {
                case .unavailable: reason = .modelUnavailable
                case .unsupported: reason = .modelUnsupported
                case .unverified, .verified: reason = .modelUnverified
                }
                failActive(attemptID: attemptID, reason: reason, model: model)
                return
            }
            guard verified.workflow.recordModel(evidence) else {
                failActive(attemptID: attemptID, reason: .modelUnverified, model: model)
                return
            }
            activeAttempt = verified
            status = verified.workflow.status
        }

        guard var ready = activeAttempt, ready.id == attemptID else { return }
        guard ready.workflow.markReady() else {
            failActive(attemptID: attemptID, reason: .modelUnverified)
            return
        }
        status = ready.workflow.status
        activeAttempt = nil
        driverTask = nil
    }

    private func failActive(
        attemptID: UUID,
        reason: LocalCLILoginFailureReason,
        model: String? = nil
    ) {
        guard var current = activeAttempt, current.id == attemptID else { return }
        _ = current.workflow.markFailed(reason, model: model)
        status = current.workflow.status
        activeAttempt = nil
        driverTask = nil
    }
}
