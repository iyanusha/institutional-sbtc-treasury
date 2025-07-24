;; Treasury Manager Contract - Foundation
;; InstitutionalBTC Treasury Protocol (IBT Protocol)

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-treasury-paused (err u104))
(define-constant err-invalid-custody-provider (err u105))
(define-constant err-withdrawal-limit-exceeded (err u106))

;; Treasury status
(define-constant status-active u1)
(define-constant status-paused u2)
(define-constant status-emergency u3)

;; Custody providers
(define-constant custody-bitgo u1)
(define-constant custody-anchorage u2)
(define-constant custody-fireblocks u3)

;; Data Variables
(define-data-var treasury-status uint status-active)
(define-data-var total-sbtc-managed uint u0)
(define-data-var daily-withdrawal-limit uint u10000000000) ;; 100 sBTC in sats
(define-data-var emergency-pause-duration uint u1440) ;; ~24 hours in blocks

;; Data Maps
(define-map institutional-accounts
  { account: principal }
  {
    is-approved: bool,
    deposit-limit: uint,
    withdrawal-limit: uint,
    custody-provider: uint,
    last-activity: uint,
    total-deposited: uint,
    total-withdrawn: uint
  }
)

(define-map treasury-balances
  { account: principal }
  {
    sbtc-balance: uint,
    yield-earned: uint,
    last-updated: uint
  }
)

(define-map custody-allocations
  { custody-provider: uint }
  {
    allocated-amount: uint,
    available-amount: uint,
    last-reconciled: uint,
    is-active: bool
  }
)

(define-map daily-withdrawal-tracking
  { date: uint, account: principal }
  { amount-withdrawn: uint }
)

(define-map yield-strategies
  { strategy-id: uint }
  {
    name: (string-ascii 64),
    allocated-amount: uint,
    current-yield: uint,
    is-active: bool,
    risk-level: uint
  }
)

(define-map governance-proposals
  { proposal-id: uint }
  {
    proposer: principal,
    proposal-type: (string-ascii 32),
    description: (string-ascii 256),
    votes-for: uint,
    votes-against: uint,
    execution-block: uint,
    is-executed: bool
  }
)

;; Read-only functions
(define-read-only (get-institutional-account (account principal))
  (map-get? institutional-accounts { account: account })
)

(define-read-only (get-treasury-balance (account principal))
  (map-get? treasury-balances { account: account })
)

(define-read-only (get-custody-allocation (provider uint))
  (map-get? custody-allocations { custody-provider: provider })
)

(define-read-only (get-total-sbtc-managed)
  (var-get total-sbtc-managed)
)

(define-read-only (get-treasury-status)
  (var-get treasury-status)
)

(define-read-only (is-treasury-operational)
  (is-eq (var-get treasury-status) status-active)
)

(define-read-only (get-daily-withdrawal-limit)
  (var-get daily-withdrawal-limit)
)

(define-read-only (calculate-available-yield (account principal))
  (match (get-treasury-balance account)
    balance (get yield-earned balance)
    u0
  )
)

;; Private functions
(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (is-approved-account (account principal))
  (match (get-institutional-account account)
    account-data (get is-approved account-data)
    false
  )
)

(define-private (validate-custody-provider (provider uint))
  (or (is-eq provider custody-bitgo)
      (is-eq provider custody-anchorage)
      (is-eq provider custody-fireblocks))
)

(define-private (get-current-date)
  (/ stacks-block-height u144) ;; Approximate days since genesis
)

(define-private (check-daily-withdrawal-limit (account principal) (amount uint))
  (let (
    (current-date (get-current-date))
    (today-withdrawn (default-to u0 
      (get amount-withdrawn 
        (map-get? daily-withdrawal-tracking { date: current-date, account: account }))))
  )
    (<= (+ today-withdrawn amount) (var-get daily-withdrawal-limit))
  )
)

;; Public functions
(define-public (approve-institutional-account
  (account principal)
  (deposit-limit uint)
  (withdrawal-limit uint)
  (custody-provider uint)
)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (validate-custody-provider custody-provider) err-invalid-custody-provider)
    (asserts! (> deposit-limit u0) err-invalid-amount)
    (asserts! (> withdrawal-limit u0) err-invalid-amount)
    
    (map-set institutional-accounts
      { account: account }
      {
        is-approved: true,
        deposit-limit: deposit-limit,
        withdrawal-limit: withdrawal-limit,
        custody-provider: custody-provider,
        last-activity: stacks-block-height,
        total-deposited: u0,
        total-withdrawn: u0
      }
    )
    
    (ok true)
  )
)

(define-public (deposit-sbtc (amount uint))
  (let (
    (account-data (unwrap! (get-institutional-account tx-sender) err-not-authorized))
    (current-balance (default-to 
      { sbtc-balance: u0, yield-earned: u0, last-updated: u0 }
      (get-treasury-balance tx-sender)))
  )
    (asserts! (is-treasury-operational) err-treasury-paused)
    (asserts! (get is-approved account-data) err-not-authorized)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (<= (+ (get total-deposited account-data) amount) 
                  (get deposit-limit account-data)) err-invalid-amount)
    
    ;; Update treasury balance
    (map-set treasury-balances
      { account: tx-sender }
      {
        sbtc-balance: (+ (get sbtc-balance current-balance) amount),
        yield-earned: (get yield-earned current-balance),
        last-updated: stacks-block-height
      }
    )
    
    ;; Update account tracking
    (map-set institutional-accounts
      { account: tx-sender }
      (merge account-data { 
        total-deposited: (+ (get total-deposited account-data) amount),
        last-activity: stacks-block-height
      })
    )
    
    ;; Update total managed
    (var-set total-sbtc-managed (+ (var-get total-sbtc-managed) amount))
    
    (ok true)
  )
)

(define-public (withdraw-sbtc (amount uint))
  (let (
    (account-data (unwrap! (get-institutional-account tx-sender) err-not-authorized))
    (current-balance (unwrap! (get-treasury-balance tx-sender) err-insufficient-balance))
    (current-date (get-current-date))
  )
    (asserts! (is-treasury-operational) err-treasury-paused)
    (asserts! (get is-approved account-data) err-not-authorized)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (<= amount (get sbtc-balance current-balance)) err-insufficient-balance)
    (asserts! (<= amount (get withdrawal-limit account-data)) err-withdrawal-limit-exceeded)
    (asserts! (check-daily-withdrawal-limit tx-sender amount) err-withdrawal-limit-exceeded)
    
    ;; Update treasury balance
    (map-set treasury-balances
      { account: tx-sender }
      {
        sbtc-balance: (- (get sbtc-balance current-balance) amount),
        yield-earned: (get yield-earned current-balance),
        last-updated: stacks-block-height
      }
    )
    
    ;; Update daily withdrawal tracking
    (let (
      (today-withdrawn (default-to u0 
        (get amount-withdrawn 
          (map-get? daily-withdrawal-tracking { date: current-date, account: tx-sender }))))
    )
      (map-set daily-withdrawal-tracking
        { date: current-date, account: tx-sender }
        { amount-withdrawn: (+ today-withdrawn amount) }
      )
    )
    
    ;; Update account tracking
    (map-set institutional-accounts
      { account: tx-sender }
      (merge account-data { 
        total-withdrawn: (+ (get total-withdrawn account-data) amount),
        last-activity: stacks-block-height
      })
    )
    
    ;; Update total managed
    (var-set total-sbtc-managed (- (var-get total-sbtc-managed) amount))
    
    (ok true)
  )
)

(define-public (allocate-to-custody
  (custody-provider uint)
  (amount uint)
)
  (let (
    (current-allocation (default-to 
      { allocated-amount: u0, available-amount: u0, last-reconciled: u0, is-active: false }
      (get-custody-allocation custody-provider)))
  )
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (validate-custody-provider custody-provider) err-invalid-custody-provider)
    (asserts! (> amount u0) err-invalid-amount)
    
    (map-set custody-allocations
      { custody-provider: custody-provider }
      {
        allocated-amount: (+ (get allocated-amount current-allocation) amount),
        available-amount: (+ (get available-amount current-allocation) amount),
        last-reconciled: stacks-block-height,
        is-active: true
      }
    )
    
    (ok true)
  )
)

(define-public (emergency-pause)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (var-set treasury-status status-emergency)
    (ok true)
  )
)

(define-public (resume-operations)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (var-set treasury-status status-active)
    (ok true)
  )
)

(define-public (update-withdrawal-limit (new-limit uint))
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (> new-limit u0) err-invalid-amount)
    (var-set daily-withdrawal-limit new-limit)
    (ok true)
  )
)

(define-public (claim-yield)
  (let (
    (current-balance (unwrap! (get-treasury-balance tx-sender) err-insufficient-balance))
    (yield-amount (get yield-earned current-balance))
  )
    (asserts! (is-treasury-operational) err-treasury-paused)
    (asserts! (is-approved-account tx-sender) err-not-authorized)
    (asserts! (> yield-amount u0) err-invalid-amount)
    
    ;; Reset yield and add to balance
    (map-set treasury-balances
      { account: tx-sender }
      {
        sbtc-balance: (+ (get sbtc-balance current-balance) yield-amount),
        yield-earned: u0,
        last-updated: stacks-block-height
      }
    )
    
    (ok yield-amount)
  )
)
