;; Fireblocks Interface Contract - Custodian Integration  
;; InstitutionalBTC Treasury Protocol (IBT Protocol)

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u400))
(define-constant err-invalid-workspace-id (err u401))
(define-constant err-mpc-signing-failed (err u402))
(define-constant err-insufficient-balance (err u403))
(define-constant err-transaction-failed (err u404))
(define-constant err-workspace-not-found (err u405))
(define-constant err-unauthorized-signer (err u406))
(define-constant err-policy-violation (err u407))
(define-constant err-key-derivation-failed (err u408))

;; Fireblocks workspace types
(define-constant workspace-main u1)
(define-constant workspace-sub u2)
(define-constant workspace-vault u3)

;; MPC signing statuses
(define-constant signing-pending u1)
(define-constant signing-approved u2)
(define-constant signing-completed u3)
(define-constant signing-failed u4)

;; Policy rule types
(define-constant policy-transfer-limit u1)
(define-constant policy-destination-whitelist u2)
(define-constant policy-time-window u3)
(define-constant policy-multi-auth u4)

;; Data Variables
(define-data-var fireblocks-api-key (string-ascii 128) "")
(define-data-var mpc-threshold uint u3) ;; 3 out of 5 signers
(define-data-var policy-engine-active bool true)

;; Data Maps
(define-map fireblocks-workspaces
  { workspace-id: (string-ascii 64) }
  {
    workspace-name: (string-ascii 64),
    workspace-type: uint,
    balance: uint,
    mpc-participants: (list 10 principal),
    signing-threshold: uint,
    policy-set-id: (string-ascii 32),
    last-activity: uint,
    is-active: bool
  }
)

(define-map mpc-transactions
  { tx-id: (string-ascii 64) }
  {
    workspace-id: (string-ascii 64),
    amount: uint,
    destination: (string-ascii 64),
    initiator: principal,
    required-signatures: uint,
    current-signatures: uint,
    signers: (list 10 principal),
    signing-status: uint,
    created-at: uint,
    completed-at: uint
  }
)

(define-map policy-sets
  { policy-set-id: (string-ascii 32) }
  {
    policy-name: (string-ascii 64),
    rules: (list 10 { rule-type: uint, parameter: uint, value: (string-ascii 64) }),
    auto-approval-threshold: uint,
    manual-review-required: bool,
    is-active: bool
  }
)

(define-map mpc-key-shares
  { participant: principal, workspace-id: (string-ascii 64) }
  {
    key-share-id: (string-ascii 64),
    derivation-path: (string-ascii 32),
    is-active: bool,
    last-used: uint
  }
)

(define-map transaction-policies
  { workspace-id: (string-ascii 64), policy-type: uint }
  {
    policy-value: uint,
    policy-data: (string-ascii 128),
    enforced: bool,
    created-at: uint
  }
)

(define-map signing-sessions
  { session-id: (string-ascii 64) }
  {
    tx-id: (string-ascii 64),
    participants: (list 10 principal),
    signatures-collected: uint,
    session-status: uint,
    timeout-block: uint
  }
)

;; Read-only functions
(define-read-only (get-fireblocks-workspace (workspace-id (string-ascii 64)))
  (map-get? fireblocks-workspaces { workspace-id: workspace-id })
)

(define-read-only (get-mpc-transaction (tx-id (string-ascii 64)))
  (map-get? mpc-transactions { tx-id: tx-id })
)

(define-read-only (get-policy-set (policy-set-id (string-ascii 32)))
  (map-get? policy-sets { policy-set-id: policy-set-id })
)

(define-read-only (get-mpc-key-share (participant principal) (workspace-id (string-ascii 64)))
  (map-get? mpc-key-shares { participant: participant, workspace-id: workspace-id })
)

(define-read-only (get-signing-session (session-id (string-ascii 64)))
  (map-get? signing-sessions { session-id: session-id })
)

(define-read-only (is-mpc-participant (participant principal) (workspace-id (string-ascii 64)))
  (match (get-fireblocks-workspace workspace-id)
    workspace (is-some (index-of (get mpc-participants workspace) participant))
    false
  )
)

(define-read-only (calculate-signing-progress (tx-id (string-ascii 64)))
  (match (get-mpc-transaction tx-id)
    transaction (if (> (get required-signatures transaction) u0)
                  (/ (* (get current-signatures transaction) u100) (get required-signatures transaction))
                  u0)
    u0
  )
)

;; Private functions
(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (validate-workspace-type (workspace-type uint))
  (or (is-eq workspace-type workspace-main)
      (is-eq workspace-type workspace-sub)
      (is-eq workspace-type workspace-vault))
)

(define-private (check-policy-compliance 
  (workspace-id (string-ascii 64))
  (amount uint)
  (destination (string-ascii 64))
)
  (match (get-fireblocks-workspace workspace-id)
    workspace (let (
      (policy-set (get-policy-set (get policy-set-id workspace)))
    )
      (match policy-set
        policies (and 
          (get is-active policies)
          (var-get policy-engine-active)
          ;; Simplified policy check - would be more complex in production
          (<= amount (get auto-approval-threshold policies))
        )
        false
      )
    )
    false
  )
)

(define-private (initiate-mpc-signing
  (tx-id (string-ascii 64))
  (workspace-id (string-ascii 64))
  (participants (list 10 principal))
)
  (let (
    (session-id tx-id)
  )
    (map-set signing-sessions
      { session-id: session-id }
      {
        tx-id: tx-id,
        participants: participants,
        signatures-collected: u0,
        session-status: signing-pending,
        timeout-block: (+ stacks-block-height u1440) ;; 24 hour timeout
      }
    )
    session-id
  )
)

;; Public functions
(define-public (register-fireblocks-workspace
  (workspace-id (string-ascii 64))
  (workspace-name (string-ascii 64))
  (workspace-type uint)
  (mpc-participants (list 10 principal))
  (signing-threshold uint)
  (policy-set-id (string-ascii 32))
)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (> (len workspace-id) u0) err-invalid-workspace-id)
    (asserts! (validate-workspace-type workspace-type) err-invalid-workspace-id)
    (asserts! (> (len mpc-participants) u0) err-unauthorized-signer)
    (asserts! (<= signing-threshold (len mpc-participants)) err-mpc-signing-failed)
    (asserts! (> signing-threshold u0) err-mpc-signing-failed)
    
    (map-set fireblocks-workspaces
      { workspace-id: workspace-id }
      {
        workspace-name: workspace-name,
        workspace-type: workspace-type,
        balance: u0,
        mpc-participants: mpc-participants,
        signing-threshold: signing-threshold,
        policy-set-id: policy-set-id,
        last-activity: stacks-block-height,
        is-active: true
      }
    )
    
    (ok true)
  )
)

(define-public (create-policy-set
  (policy-set-id (string-ascii 32))
  (policy-name (string-ascii 64))
  (auto-approval-threshold uint)
  (manual-review-required bool)
  (rules (list 10 { rule-type: uint, parameter: uint, value: (string-ascii 64) }))
)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (> (len policy-set-id) u0) err-policy-violation)
    (asserts! (> auto-approval-threshold u0) err-policy-violation)
    
    (map-set policy-sets
      { policy-set-id: policy-set-id }
      {
        policy-name: policy-name,
        rules: rules,
        auto-approval-threshold: auto-approval-threshold,
        manual-review-required: manual-review-required,
        is-active: true
      }
    )
    
    (ok true)
  )
)

(define-public (initiate-mpc-transaction
  (tx-id (string-ascii 64))
  (workspace-id (string-ascii 64))
  (amount uint)
  (destination (string-ascii 64))
)
  (let (
    (workspace (unwrap! (get-fireblocks-workspace workspace-id) err-workspace-not-found))
  )
    (asserts! (is-mpc-participant tx-sender workspace-id) err-unauthorized-signer)
    (asserts! (get is-active workspace) err-workspace-not-found)
    (asserts! (> amount u0) err-insufficient-balance)
    (asserts! (<= amount (get balance workspace)) err-insufficient-balance)
    (asserts! (check-policy-compliance workspace-id amount destination) err-policy-violation)
    
    (map-set mpc-transactions
      { tx-id: tx-id }
      {
        workspace-id: workspace-id,
        amount: amount,
        destination: destination,
        initiator: tx-sender,
        required-signatures: (get signing-threshold workspace),
        current-signatures: u1,
        signers: (list tx-sender),
        signing-status: signing-pending,
        created-at: stacks-block-height,
        completed-at: u0
      }
    )
    
    ;; Initiate MPC signing session
    (let (
      (session-id (initiate-mpc-signing tx-id workspace-id (get mpc-participants workspace)))
    )
      (ok { tx-id: tx-id, session-id: session-id })
    )
  )
)

(define-public (sign-mpc-transaction (tx-id (string-ascii 64)))
  (let (
    (transaction (unwrap! (get-mpc-transaction tx-id) err-transaction-failed))
    (workspace (unwrap! (get-fireblocks-workspace (get workspace-id transaction)) err-workspace-not-found))
  )
    (asserts! (is-mpc-participant tx-sender (get workspace-id transaction)) err-unauthorized-signer)
    (asserts! (is-eq (get signing-status transaction) signing-pending) err-transaction-failed)
    (asserts! (is-none (index-of (get signers transaction) tx-sender)) err-transaction-failed)
    
    (let (
      (new-signatures (+ (get current-signatures transaction) u1))
      (new-signers (unwrap! (as-max-len? (append (get signers transaction) tx-sender) u10) err-transaction-failed))
    )
      (map-set mpc-transactions
        { tx-id: tx-id }
        (merge transaction {
          current-signatures: new-signatures,
          signers: new-signers,
          signing-status: (if (>= new-signatures (get required-signatures transaction)) 
                           signing-approved signing-pending)
        })
      )
      
      (ok new-signatures)
    )
  )
)

(define-public (execute-mpc-transaction (tx-id (string-ascii 64)))
  (let (
    (transaction (unwrap! (get-mpc-transaction tx-id) err-transaction-failed))
    (workspace (unwrap! (get-fireblocks-workspace (get workspace-id transaction)) err-workspace-not-found))
  )
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (is-eq (get signing-status transaction) signing-approved) err-transaction-failed)
    (asserts! (>= (get current-signatures transaction) (get required-signatures transaction)) err-mpc-signing-failed)
    
    ;; Update workspace balance
    (map-set fireblocks-workspaces
      { workspace-id: (get workspace-id transaction) }
      (merge workspace {
        balance: (- (get balance workspace) (get amount transaction)),
        last-activity: stacks-block-height
      })
    )
    
    ;; Mark transaction as completed
    (map-set mpc-transactions
      { tx-id: tx-id }
      (merge transaction {
        signing-status: signing-completed,
        completed-at: stacks-block-height
      })
    )
    
    (ok true)
  )
)

(define-public (assign-mpc-key-share
  (participant principal)
  (workspace-id (string-ascii 64))
  (key-share-id (string-ascii 64))
  (derivation-path (string-ascii 32))
)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (is-mpc-participant participant workspace-id) err-unauthorized-signer)
    
    (map-set mpc-key-shares
      { participant: participant, workspace-id: workspace-id }
      {
        key-share-id: key-share-id,
        derivation-path: derivation-path,
        is-active: true,
        last-used: stacks-block-height
      }
    )
    
    (ok true)
  )
)

(define-public (update-workspace-balance
  (workspace-id (string-ascii 64))
  (new-balance uint)
)
  (let (
    (workspace (unwrap! (get-fireblocks-workspace workspace-id) err-workspace-not-found))
  )
    (asserts! (is-contract-owner) err-owner-only)
    
    (map-set fireblocks-workspaces
      { workspace-id: workspace-id }
      (merge workspace {
        balance: new-balance,
        last-activity: stacks-block-height
      })
    )
    
    (ok true)
  )
)

(define-public (set-transaction-policy
  (workspace-id (string-ascii 64))
  (policy-type uint)
  (policy-value uint)
  (policy-data (string-ascii 128))
)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (is-some (get-fireblocks-workspace workspace-id)) err-workspace-not-found)
    
    (map-set transaction-policies
      { workspace-id: workspace-id, policy-type: policy-type }
      {
        policy-value: policy-value,
        policy-data: policy-data,
        enforced: true,
        created-at: stacks-block-height
      }
    )
    
    (ok true)
  )
)

(define-public (emergency-freeze-workspace (workspace-id (string-ascii 64)))
  (let (
    (workspace (unwrap! (get-fireblocks-workspace workspace-id) err-workspace-not-found))
  )
    (asserts! (is-contract-owner) err-owner-only)
    
    (map-set fireblocks-workspaces
      { workspace-id: workspace-id }
      (merge workspace { is-active: false })
    )
    
    (ok true)
  )
)

(define-public (cancel-mpc-transaction (tx-id (string-ascii 64)))
  (let (
    (transaction (unwrap! (get-mpc-transaction tx-id) err-transaction-failed))
  )
    (asserts! (or (is-eq tx-sender (get initiator transaction)) (is-contract-owner)) err-unauthorized-signer)
    (asserts! (not (is-eq (get signing-status transaction) signing-completed)) err-transaction-failed)
    
    (map-set mpc-transactions
      { tx-id: tx-id }
      (merge transaction { signing-status: signing-failed })
    )
    
    (ok true)
  )
)

(define-public (update-mpc-threshold (new-threshold uint))
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (and (>= new-threshold u2) (<= new-threshold u10)) err-mpc-signing-failed)
    
    (var-set mpc-threshold new-threshold)
    (ok true)
  )
)

(define-public (toggle-policy-engine (active bool))
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (var-set policy-engine-active active)
    (ok true)
  )
)
