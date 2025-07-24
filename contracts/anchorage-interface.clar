;; Anchorage Digital Interface Contract - Phase 2: Custodian Integration
;; InstitutionalBTC Treasury Protocol (IBT Protocol)

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u300))
(define-constant err-invalid-vault-id (err u301))
(define-constant err-policy-violation (err u302))
(define-constant err-insufficient-balance (err u303))
(define-constant err-transfer-failed (err u304))
(define-constant err-vault-not-found (err u305))
(define-constant err-unauthorized-operator (err u306))
(define-constant err-compliance-check-failed (err u307))
(define-constant err-cooling-period-active (err u308))

;; Anchorage Digital vault types
(define-constant vault-custody u1)
(define-constant vault-trading u2)
(define-constant vault-staking u3)

;; Transfer statuses
(define-constant status-pending u1)
(define-constant status-approved u2)
(define-constant status-executed u3)
(define-constant status-cancelled u4)

;; Data Variables
(define-data-var anchorage-api-token (string-ascii 128) "")
(define-data-var compliance-officer principal tx-sender)
(define-data-var cooling-period-duration uint u4320) ;; ~30 days in blocks

;; Data Maps
(define-map anchorage-vaults
  { vault-id: (string-ascii 64) }
  {
    vault-name: (string-ascii 64),
    vault-type: uint,
    balance: uint,
    available-balance: uint,
    policy-id: (string-ascii 32),
    operators: (list 5 principal),
    last-activity: uint,
    is-active: bool
  }
)

(define-map transfer-requests
  { request-id: (string-ascii 64) }
  {
    from-vault: (string-ascii 64),
    to-address: (string-ascii 64),
    amount: uint,
    requester: principal,
    status: uint,
    compliance-approved: bool,
    policy-checks: (list 5 (string-ascii 32)),
    created-at: uint,
    approved-at: uint
  }
)

(define-map compliance-policies
  { policy-id: (string-ascii 32) }
  {
    policy-name: (string-ascii 64),
    max-daily-transfer: uint,
    requires-dual-approval: bool,
    cooling-period-required: bool,
    whitelisted-addresses: (list 20 (string-ascii 64)),
    is-active: bool
  }
)

(define-map operator-permissions
  { operator: principal, vault-id: (string-ascii 64) }
  {
    can-initiate-transfers: bool,
    can-approve-transfers: bool,
    daily-limit: uint,
    used-today: uint,
    last-activity: uint
  }
)

(define-map daily-transfer-limits
  { date: uint, vault-id: (string-ascii 64) }
  { total-transferred: uint }
)

(define-map audit-logs
  { log-id: uint }
  {
    action: (string-ascii 32),
    vault-id: (string-ascii 64),
    operator: principal,
    amount: uint,
    timestamp: uint,
    details: (string-ascii 128)
  }
)

;; Read-only functions
(define-read-only (get-anchorage-vault (vault-id (string-ascii 64)))
  (map-get? anchorage-vaults { vault-id: vault-id })
)

(define-read-only (get-transfer-request (request-id (string-ascii 64)))
  (map-get? transfer-requests { request-id: request-id })
)

(define-read-only (get-compliance-policy (policy-id (string-ascii 32)))
  (map-get? compliance-policies { policy-id: policy-id })
)

(define-read-only (get-operator-permissions (operator principal) (vault-id (string-ascii 64)))
  (map-get? operator-permissions { operator: operator, vault-id: vault-id })
)

(define-read-only (get-daily-transfer-limit (date uint) (vault-id (string-ascii 64)))
  (map-get? daily-transfer-limits { date: date, vault-id: vault-id })
)

(define-read-only (is-authorized-operator (operator principal) (vault-id (string-ascii 64)))
  (match (get-anchorage-vault vault-id)
    vault (is-some (index-of (get operators vault) operator))
    false
  )
)

(define-read-only (calculate-vault-utilization (vault-id (string-ascii 64)))
  (match (get-anchorage-vault vault-id)
    vault (if (> (get balance vault) u0)
            (/ (* (- (get balance vault) (get available-balance vault)) u10000) (get balance vault))
            u0)
    u0
  )
)

;; Private functions
(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (is-compliance-officer)
  (is-eq tx-sender (var-get compliance-officer))
)

(define-private (validate-vault-type (vault-type uint))
  (or (is-eq vault-type vault-custody)
      (is-eq vault-type vault-trading)
      (is-eq vault-type vault-staking))
)

(define-private (get-current-date)
  (/ stacks-block-height u144) ;; Approximate days since genesis
)

(define-private (check-policy-compliance 
  (vault-id (string-ascii 64))
  (amount uint)
  (to-address (string-ascii 64))
)
  (match (get-anchorage-vault vault-id)
    vault (match (get-compliance-policy (get policy-id vault))
      policy (let (
        (current-date (get-current-date))
        (daily-total (default-to u0 
          (get total-transferred 
            (get-daily-transfer-limit current-date vault-id))))
        (is-whitelisted (is-some (index-of (get whitelisted-addresses policy) to-address)))
      )
        (and 
          (get is-active policy)
          (<= (+ daily-total amount) (get max-daily-transfer policy))
          (or (not (get cooling-period-required policy)) 
              (> (- stacks-block-height (get last-activity vault)) (var-get cooling-period-duration)))
          is-whitelisted
        )
      )
      false
    )
    false
  )
)

(define-private (log-audit-event
  (action (string-ascii 32))
  (vault-id (string-ascii 64))
  (amount uint)
  (details (string-ascii 128))
  (log-id uint)
)
  (map-set audit-logs
    { log-id: log-id }
    {
      action: action,
      vault-id: vault-id,
      operator: tx-sender,
      amount: amount,
      timestamp: stacks-block-height,
      details: details
    }
  )
)

;; Public functions
(define-public (register-anchorage-vault
  (vault-id (string-ascii 64))
  (vault-name (string-ascii 64))
  (vault-type uint)
  (policy-id (string-ascii 32))
  (operators (list 5 principal))
)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (> (len vault-id) u0) err-invalid-vault-id)
    (asserts! (> (len vault-name) u0) err-invalid-vault-id)
    (asserts! (validate-vault-type vault-type) err-invalid-vault-id)
    (asserts! (> (len operators) u0) err-unauthorized-operator)
    
    (map-set anchorage-vaults
      { vault-id: vault-id }
      {
        vault-name: vault-name,
        vault-type: vault-type,
        balance: u0,
        available-balance: u0,
        policy-id: policy-id,
        operators: operators,
        last-activity: stacks-block-height,
        is-active: true
      }
    )
    
    (ok true)
  )
)

(define-public (create-compliance-policy
  (policy-id (string-ascii 32))
  (policy-name (string-ascii 64))
  (max-daily-transfer uint)
  (requires-dual-approval bool)
  (cooling-period-required bool)
  (whitelisted-addresses (list 20 (string-ascii 64)))
)
  (begin
    (asserts! (is-compliance-officer) err-owner-only)
    (asserts! (> (len policy-id) u0) err-policy-violation)
    (asserts! (> max-daily-transfer u0) err-policy-violation)
    
    (map-set compliance-policies
      { policy-id: policy-id }
      {
        policy-name: policy-name,
        max-daily-transfer: max-daily-transfer,
        requires-dual-approval: requires-dual-approval,
        cooling-period-required: cooling-period-required,
        whitelisted-addresses: whitelisted-addresses,
        is-active: true
      }
    )
    
    (ok true)
  )
)

(define-public (update-vault-balance
  (vault-id (string-ascii 64))
  (new-balance uint)
  (new-available-balance uint)
)
  (let (
    (vault (unwrap! (get-anchorage-vault vault-id) err-vault-not-found))
  )
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (<= new-available-balance new-balance) err-insufficient-balance)
    
    (map-set anchorage-vaults
      { vault-id: vault-id }
      (merge vault {
        balance: new-balance,
        available-balance: new-available-balance,
        last-activity: stacks-block-height
      })
    )
    
    (ok true)
  )
)

(define-public (initiate-transfer
  (request-id (string-ascii 64))
  (from-vault (string-ascii 64))
  (to-address (string-ascii 64))
  (amount uint)
)
  (let (
    (vault (unwrap! (get-anchorage-vault from-vault) err-vault-not-found))
  )
    (asserts! (is-authorized-operator tx-sender from-vault) err-unauthorized-operator)
    (asserts! (get is-active vault) err-vault-not-found)
    (asserts! (> amount u0) err-insufficient-balance)
    (asserts! (<= amount (get available-balance vault)) err-insufficient-balance)
    (asserts! (check-policy-compliance from-vault amount to-address) err-policy-violation)
    
    (map-set transfer-requests
      { request-id: request-id }
      {
        from-vault: from-vault,
        to-address: to-address,
        amount: amount,
        requester: tx-sender,
        status: status-pending,
        compliance-approved: false,
        policy-checks: (list "whitelist-check" "daily-limit-check"),
        created-at: stacks-block-height,
        approved-at: u0
      }
    )
    
    (log-audit-event "transfer-initiated" from-vault amount "Transfer request created" u0)
    (ok request-id)
  )
)

(define-public (approve-transfer-compliance (request-id (string-ascii 64)))
  (let (
    (request (unwrap! (get-transfer-request request-id) err-transfer-failed))
  )
    (asserts! (is-compliance-officer) err-owner-only)
    (asserts! (is-eq (get status request) status-pending) err-transfer-failed)
    
    (map-set transfer-requests
      { request-id: request-id }
      (merge request {
        compliance-approved: true,
        status: status-approved,
        approved-at: stacks-block-height
      })
    )
    
    (log-audit-event "compliance-approved" (get from-vault request) (get amount request) "Compliance approval granted" u1)
    (ok true)
  )
)

(define-public (execute-approved-transfer (request-id (string-ascii 64)))
  (let (
    (request (unwrap! (get-transfer-request request-id) err-transfer-failed))
    (vault (unwrap! (get-anchorage-vault (get from-vault request)) err-vault-not-found))
  )
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (is-eq (get status request) status-approved) err-transfer-failed)
    (asserts! (get compliance-approved request) err-compliance-check-failed)
    
    ;; Update vault balances
    (map-set anchorage-vaults
      { vault-id: (get from-vault request) }
      (merge vault {
        balance: (- (get balance vault) (get amount request)),
        available-balance: (- (get available-balance vault) (get amount request)),
        last-activity: stacks-block-height
      })
    )
    
    ;; Update daily transfer tracking
    (let (
      (current-date (get-current-date))
      (current-daily (default-to u0 
        (get total-transferred 
          (get-daily-transfer-limit current-date (get from-vault request)))))
    )
      (map-set daily-transfer-limits
        { date: current-date, vault-id: (get from-vault request) }
        { total-transferred: (+ current-daily (get amount request)) }
      )
    )
    
    ;; Mark transfer as executed
    (map-set transfer-requests
      { request-id: request-id }
      (merge request { status: status-executed })
    )
    
    (log-audit-event "transfer-executed" (get from-vault request) (get amount request) "Transfer completed successfully" u2)
    (ok true)
  )
)

(define-public (set-operator-permissions
  (operator principal)
  (vault-id (string-ascii 64))
  (can-initiate bool)
  (can-approve bool)
  (daily-limit uint)
)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (is-authorized-operator operator vault-id) err-unauthorized-operator)
    
    (map-set operator-permissions
      { operator: operator, vault-id: vault-id }
      {
        can-initiate-transfers: can-initiate,
        can-approve-transfers: can-approve,
        daily-limit: daily-limit,
        used-today: u0,
        last-activity: stacks-block-height
      }
    )
    
    (ok true)
  )
)

(define-public (emergency-freeze-vault (vault-id (string-ascii 64)))
  (let (
    (vault (unwrap! (get-anchorage-vault vault-id) err-vault-not-found))
  )
    (asserts! (or (is-contract-owner) (is-compliance-officer)) err-owner-only)
    
    (map-set anchorage-vaults
      { vault-id: vault-id }
      (merge vault { is-active: false })
    )
    
    (log-audit-event "vault-frozen" vault-id u0 "Emergency vault freeze activated" u3)
    (ok true)
  )
)

(define-public (cancel-transfer (request-id (string-ascii 64)))
  (let (
    (request (unwrap! (get-transfer-request request-id) err-transfer-failed))
  )
    (asserts! (or (is-eq tx-sender (get requester request)) (is-compliance-officer)) err-unauthorized-operator)
    (asserts! (not (is-eq (get status request) status-executed)) err-transfer-failed)
    
    (map-set transfer-requests
      { request-id: request-id }
      (merge request { status: status-cancelled })
    )
    
    (log-audit-event "transfer-cancelled" (get from-vault request) (get amount request) "Transfer request cancelled" u4)
    (ok true)
  )
)

(define-public (set-compliance-officer (new-officer principal))
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (var-set compliance-officer new-officer)
    (ok true)
  )
)

(define-public (update-cooling-period (new-duration uint))
  (begin
    (asserts! (is-compliance-officer) err-owner-only)
    (asserts! (> new-duration u0) err-policy-violation)
    (var-set cooling-period-duration new-duration)
    (ok true)
  )
)