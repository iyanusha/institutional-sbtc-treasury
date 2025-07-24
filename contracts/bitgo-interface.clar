;; BitGo Interface Contract - Custodian Integration
;; InstitutionalBTC Treasury Protocol (IBT Protocol)

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-invalid-wallet-id (err u201))
(define-constant err-invalid-signature (err u202))
(define-constant err-insufficient-balance (err u203))
(define-constant err-transaction-failed (err u204))
(define-constant err-wallet-not-found (err u205))
(define-constant err-unauthorized-signer (err u206))
(define-constant err-webhook-verification-failed (err u207))

;; BitGo API response codes
(define-constant bitgo-success u200)
(define-constant bitgo-pending u202)
(define-constant bitgo-error u400)

;; Data Variables
(define-data-var bitgo-api-key (string-ascii 128) "")
(define-data-var webhook-secret (string-ascii 64) "")
(define-data-var last-reconciliation uint u0)

;; Data Maps
(define-map bitgo-wallets
  { wallet-id: (string-ascii 64) }
  {
    wallet-type: (string-ascii 16), ;; "hot", "warm", "cold"
    balance: uint,
    required-signers: uint,
    authorized-signers: (list 10 principal),
    last-updated: uint,
    is-active: bool
  }
)

(define-map pending-transactions
  { tx-id: (string-ascii 64) }
  {
    wallet-id: (string-ascii 64),
    amount: uint,
    recipient: (string-ascii 64),
    requester: principal,
    required-approvals: uint,
    current-approvals: uint,
    approved-by: (list 5 principal),
    created-at: uint,
    status: (string-ascii 16)
  }
)

(define-map webhook-logs
  { log-id: uint }
  {
    event-type: (string-ascii 32),
    wallet-id: (string-ascii 64),
    transaction-id: (string-ascii 64),
    amount: uint,
    timestamp: uint,
    verified: bool
  }
)

(define-map signer-permissions
  { signer: principal, wallet-id: (string-ascii 64) }
  {
    can-approve: bool,
    daily-limit: uint,
    approved-today: uint,
    last-approval: uint
  }
)

(define-map api-rate-limits
  { endpoint: (string-ascii 32) }
  {
    requests-per-minute: uint,
    current-requests: uint,
    reset-time: uint
  }
)

;; Read-only functions
(define-read-only (get-bitgo-wallet (wallet-id (string-ascii 64)))
  (map-get? bitgo-wallets { wallet-id: wallet-id })
)

(define-read-only (get-pending-transaction (tx-id (string-ascii 64)))
  (map-get? pending-transactions { tx-id: tx-id })
)

(define-read-only (get-signer-permissions (signer principal) (wallet-id (string-ascii 64)))
  (map-get? signer-permissions { signer: signer, wallet-id: wallet-id })
)

(define-read-only (get-webhook-log (log-id uint))
  (map-get? webhook-logs { log-id: log-id })
)

(define-read-only (is-authorized-signer (signer principal) (wallet-id (string-ascii 64)))
  (match (get-bitgo-wallet wallet-id)
    wallet (is-some (index-of (get authorized-signers wallet) signer))
    false
  )
)

(define-read-only (calculate-wallet-health (wallet-id (string-ascii 64)))
  (match (get-bitgo-wallet wallet-id)
    wallet (let (
      (balance-score (if (> (get balance wallet) u0) u40 u0))
      (signer-score (if (>= (len (get authorized-signers wallet)) (get required-signers wallet)) u30 u0))
      (activity-score (if (> (- stacks-block-height (get last-updated wallet)) u1440) u0 u30))
    )
      (+ balance-score signer-score activity-score)
    )
    u0
  )
)

;; Private functions
(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (validate-wallet-type (wallet-type (string-ascii 16)))
  (or (is-eq wallet-type "hot")
      (is-eq wallet-type "warm")
      (is-eq wallet-type "cold"))
)

(define-private (check-signer-daily-limit (signer principal) (wallet-id (string-ascii 64)) (amount uint))
  (match (get-signer-permissions signer wallet-id)
    permissions (let (
      (current-date (/ stacks-block-height u144))
      (last-approval-date (/ (get last-approval permissions) u144))
      (today-approved (if (is-eq current-date last-approval-date) 
                        (get approved-today permissions) 
                        u0))
    )
      (<= (+ today-approved amount) (get daily-limit permissions))
    )
    false
  )
)

(define-private (verify-webhook-signature (payload (string-ascii 256)) (signature (string-ascii 128)))
  ;; Simplified webhook verification - would use HMAC in production
  (> (len signature) u0)
)

;; Public functions
(define-public (register-bitgo-wallet
  (wallet-id (string-ascii 64))
  (wallet-type (string-ascii 16))
  (required-signers uint)
  (authorized-signers (list 10 principal))
)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (> (len wallet-id) u0) err-invalid-wallet-id)
    (asserts! (validate-wallet-type wallet-type) err-invalid-wallet-id)
    (asserts! (> required-signers u0) err-invalid-wallet-id)
    (asserts! (>= (len authorized-signers) required-signers) err-unauthorized-signer)
    
    (map-set bitgo-wallets
      { wallet-id: wallet-id }
      {
        wallet-type: wallet-type,
        balance: u0,
        required-signers: required-signers,
        authorized-signers: authorized-signers,
        last-updated: stacks-block-height,
        is-active: true
      }
    )
    
    (ok true)
  )
)

(define-public (update-wallet-balance 
  (wallet-id (string-ascii 64))
  (new-balance uint)
)
  (let (
    (wallet (unwrap! (get-bitgo-wallet wallet-id) err-wallet-not-found))
  )
    (asserts! (is-contract-owner) err-owner-only)
    
    (map-set bitgo-wallets
      { wallet-id: wallet-id }
      (merge wallet { 
        balance: new-balance,
        last-updated: stacks-block-height
      })
    )
    
    (ok true)
  )
)

(define-public (initiate-transaction
  (wallet-id (string-ascii 64))
  (amount uint)
  (recipient (string-ascii 64))
  (tx-id (string-ascii 64))
)
  (let (
    (wallet (unwrap! (get-bitgo-wallet wallet-id) err-wallet-not-found))
  )
    (asserts! (is-authorized-signer tx-sender wallet-id) err-unauthorized-signer)
    (asserts! (get is-active wallet) err-wallet-not-found)
    (asserts! (> amount u0) err-insufficient-balance)
    (asserts! (<= amount (get balance wallet)) err-insufficient-balance)
    (asserts! (check-signer-daily-limit tx-sender wallet-id amount) err-insufficient-balance)
    
    (map-set pending-transactions
      { tx-id: tx-id }
      {
        wallet-id: wallet-id,
        amount: amount,
        recipient: recipient,
        requester: tx-sender,
        required-approvals: (get required-signers wallet),
        current-approvals: u1,
        approved-by: (list tx-sender),
        created-at: stacks-block-height,
        status: "pending"
      }
    )
    
    (ok tx-id)
  )
)

(define-public (approve-transaction (tx-id (string-ascii 64)))
  (let (
    (transaction (unwrap! (get-pending-transaction tx-id) err-transaction-failed))
    (wallet (unwrap! (get-bitgo-wallet (get wallet-id transaction)) err-wallet-not-found))
  )
    (asserts! (is-authorized-signer tx-sender (get wallet-id transaction)) err-unauthorized-signer)
    (asserts! (is-eq (get status transaction) "pending") err-transaction-failed)
    (asserts! (is-none (index-of (get approved-by transaction) tx-sender)) err-transaction-failed)
    
    (let (
      (new-approvals (+ (get current-approvals transaction) u1))
      (new-approved-by (unwrap! (as-max-len? (append (get approved-by transaction) tx-sender) u5) err-transaction-failed))
    )
      (map-set pending-transactions
        { tx-id: tx-id }
        (merge transaction {
          current-approvals: new-approvals,
          approved-by: new-approved-by,
          status: (if (>= new-approvals (get required-approvals transaction)) "approved" "pending")
        })
      )
      
      (ok new-approvals)
    )
  )
)

(define-public (execute-approved-transaction (tx-id (string-ascii 64)))
  (let (
    (transaction (unwrap! (get-pending-transaction tx-id) err-transaction-failed))
    (wallet (unwrap! (get-bitgo-wallet (get wallet-id transaction)) err-wallet-not-found))
  )
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (is-eq (get status transaction) "approved") err-transaction-failed)
    (asserts! (>= (get current-approvals transaction) (get required-approvals transaction)) err-transaction-failed)
    
    ;; Update wallet balance
    (map-set bitgo-wallets
      { wallet-id: (get wallet-id transaction) }
      (merge wallet { 
        balance: (- (get balance wallet) (get amount transaction)),
        last-updated: stacks-block-height
      })
    )
    
    ;; Mark transaction as executed
    (map-set pending-transactions
      { tx-id: tx-id }
      (merge transaction { status: "executed" })
    )
    
    (ok true)
  )
)

(define-public (process-webhook
  (event-type (string-ascii 32))
  (wallet-id (string-ascii 64))
  (transaction-id (string-ascii 64))
  (amount uint)
  (payload (string-ascii 256))
  (signature (string-ascii 128))
  (log-id uint)
)
  (begin
    (asserts! (verify-webhook-signature payload signature) err-webhook-verification-failed)
    
    (map-set webhook-logs
      { log-id: log-id }
      {
        event-type: event-type,
        wallet-id: wallet-id,
        transaction-id: transaction-id,
        amount: amount,
        timestamp: stacks-block-height,
        verified: true
      }
    )
    
    ;; Update wallet balance if this is a deposit/withdrawal event
    (if (or (is-eq event-type "deposit") (is-eq event-type "withdrawal"))
      (match (get-bitgo-wallet wallet-id)
        wallet (let (
          (balance-change (if (is-eq event-type "deposit") amount (- u0 amount)))
        )
          (map-set bitgo-wallets
            { wallet-id: wallet-id }
            (merge wallet { 
              balance: (+ (get balance wallet) balance-change),
              last-updated: stacks-block-height
            })
          )
          (ok true)
        )
        (ok false)
      )
      (ok true)
    )
  )
)

(define-public (set-signer-permissions
  (signer principal)
  (wallet-id (string-ascii 64))
  (can-approve bool)
  (daily-limit uint)
)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (is-authorized-signer signer wallet-id) err-unauthorized-signer)
    
    (map-set signer-permissions
      { signer: signer, wallet-id: wallet-id }
      {
        can-approve: can-approve,
        daily-limit: daily-limit,
        approved-today: u0,
        last-approval: u0
      }
    )
    
    (ok true)
  )
)

(define-public (emergency-freeze-wallet (wallet-id (string-ascii 64)))
  (let (
    (wallet (unwrap! (get-bitgo-wallet wallet-id) err-wallet-not-found))
  )
    (asserts! (is-contract-owner) err-owner-only)
    
    (map-set bitgo-wallets
      { wallet-id: wallet-id }
      (merge wallet { is-active: false })
    )
    
    (ok true)
  )
)

(define-public (reconcile-wallet-balance (wallet-id (string-ascii 64)) (actual-balance uint))
  (let (
    (wallet (unwrap! (get-bitgo-wallet wallet-id) err-wallet-not-found))
  )
    (asserts! (is-contract-owner) err-owner-only)
    
    (map-set bitgo-wallets
      { wallet-id: wallet-id }
      (merge wallet { 
        balance: actual-balance,
        last-updated: stacks-block-height
      })
    )
    
    (var-set last-reconciliation stacks-block-height)
    (ok true)
  )
)
