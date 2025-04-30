;; CoinVine Core Contract
;; This contract manages creator profiles, reward mechanisms, and supporter relationships
;; for the CoinVine platform, enabling direct economic relationships between content creators
;; and their communities without intermediaries.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-EXISTS (err u102))
(define-constant ERR-INVALID-AMOUNT (err u103))
(define-constant ERR-SUBSCRIPTION-EXPIRED (err u104))
(define-constant ERR-INVALID-SUBSCRIPTION (err u105))
(define-constant ERR-PLATFORM-ONLY (err u106))
(define-constant ERR-INVALID-PERK (err u107))
(define-constant ERR-INSUFFICIENT-FUNDS (err u108))

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant PLATFORM-FEE-PERCENTAGE u5) ;; 5% platform fee
(define-constant MIN-TIP-AMOUNT u1000) ;; Minimum tip amount in microSTX

;; Data structures

;; Creator profiles
(define-map creators
  { creator-id: uint }
  {
    owner: principal,
    name: (string-ascii 64),
    description: (string-utf8 500),
    content-url: (string-utf8 256),
    creation-time: uint,
    total-rewards: uint,
    subscriber-count: uint,
    verified: bool
  }
)

;; Track the next available creator ID
(define-data-var next-creator-id uint u1)

;; Map of principal to creator-id for quick lookups
(define-map principal-to-creator-id
  { owner: principal }
  { creator-id: uint }
)

;; Subscription tiers for creators
(define-map subscription-tiers
  { creator-id: uint, tier-id: uint }
  {
    name: (string-ascii 64),
    price: uint,
    duration-days: uint,
    description: (string-utf8 500)
  }
)

;; Active subscriptions 
(define-map subscriptions
  { supporter: principal, creator-id: uint }
  {
    tier-id: uint,
    start-time: uint,
    end-time: uint,
    auto-renew: bool
  }
)

;; Special perks offered by creators
(define-map perks
  { creator-id: uint, perk-id: uint }
  {
    name: (string-ascii 64),
    price: uint,
    description: (string-utf8 500),
    available-count: (optional uint),
    sold-count: uint
  }
)

;; Track the next available perk ID for each creator
(define-map next-perk-id
  { creator-id: uint }
  { next-id: uint }
)

;; Reward history for transparency
(define-map rewards
  { tx-id: (buff 32) }
  {
    creator-id: uint,
    supporter: principal,
    amount: uint,
    reward-type: (string-ascii 20), ;; "tip", "subscription", "perk"
    time: uint,
    message: (optional (string-utf8 280)),
    anonymous: bool
  }
)

;; Platform configuration
(define-data-var platform-wallet principal CONTRACT-OWNER)
(define-data-var platform-fee-percentage uint PLATFORM-FEE-PERCENTAGE)

;; Private functions

;; Calculate platform fee amount based on total amount
(define-private (calculate-platform-fee (amount uint))
  (/ (* amount (var-get platform-fee-percentage)) u100)
)

;; Check if caller is the owner of a creator profile
(define-private (is-creator-owner (creator-id uint))
  (match (map-get? creators { creator-id: creator-id })
    profile (is-eq tx-sender (get owner profile))
    false
  )
)

;; Check if a subscription is active
(define-private (is-subscription-active (supporter principal) (creator-id uint))
  (match (map-get? subscriptions { supporter: supporter, creator-id: creator-id })
    subscription (> (get end-time subscription) block-height)
    false
  )
)

;; Record a reward transaction
(define-private (record-reward 
                  (creator-id uint) 
                  (amount uint)
                  (reward-type (string-ascii 20))
                  (message (optional (string-utf8 280)))
                  (anonymous bool))
  (let (
    (tx-id (unwrap-panic (get-block-info? id-header-hash block-height)))
  )
    (map-set rewards
      { tx-id: tx-id }
      {
        creator-id: creator-id,
        supporter: tx-sender,
        amount: amount,
        reward-type: reward-type,
        time: block-height,
        message: message,
        anonymous: anonymous
      }
    )
  )
)

;; Update a creator's total rewards
(define-private (update-creator-rewards (creator-id uint) (amount uint))
  (match (map-get? creators { creator-id: creator-id })
    profile (map-set creators
              { creator-id: creator-id }
              (merge profile { total-rewards: (+ (get total-rewards profile) amount) })
            )
    false
  )
)

;; Get creator ID for a principal
(define-private (get-creator-id-by-principal (owner principal))
  (match (map-get? principal-to-creator-id { owner: owner })
    id-map (ok (get creator-id id-map))
    (err "Creator not found")
  )
)

;; Transfer STX with platform fee
(define-private (transfer-with-fee (creator-id uint) (amount uint))
  (let (
    (creator-profile (unwrap! (map-get? creators { creator-id: creator-id }) ERR-NOT-FOUND))
    (creator-principal (get owner creator-profile))
    (fee (calculate-platform-fee amount))
    (creator-amount (- amount fee))
  )
    ;; Transfer platform fee
    (if (> fee u0)
      (unwrap! (stx-transfer? fee tx-sender (var-get platform-wallet)) ERR-INSUFFICIENT-FUNDS)
      true
    )
    
    ;; Transfer remainder to creator
    (and
      (unwrap! (stx-transfer? creator-amount tx-sender creator-principal) ERR-INSUFFICIENT-FUNDS)
      (update-creator-rewards creator-id amount)
      true
    )
  )
)

;; Read-only functions

;; Get creator profile information
(define-read-only (get-creator-profile (creator-id uint))
  (map-get? creators { creator-id: creator-id })
)

;; Get creator profile by principal
(define-read-only (get-creator-by-principal (owner principal))
  (match (map-get? principal-to-creator-id { owner: owner })
    id-map (map-get? creators { creator-id: (get creator-id id-map) })
    none
  )
)

;; Get subscription tier details
(define-read-only (get-subscription-tier (creator-id uint) (tier-id uint))
  (map-get? subscription-tiers { creator-id: creator-id, tier-id: tier-id })
)

;; Get subscription status for a supporter
(define-read-only (get-subscription-status (supporter principal) (creator-id uint))
  (map-get? subscriptions { supporter: supporter, creator-id: creator-id })
)

;; Get perk details
(define-read-only (get-perk (creator-id uint) (perk-id uint))
  (map-get? perks { creator-id: creator-id, perk-id: perk-id })
)

;; Check if user is subscribed to a creator
(define-read-only (is-subscribed (supporter principal) (creator-id uint))
  (match (map-get? subscriptions { supporter: supporter, creator-id: creator-id })
    subscription (> (get end-time subscription) block-height)
    false
  )
)

;; Public functions

;; Register a new creator profile
(define-public (register-creator (name (string-ascii 64)) (description (string-utf8 500)) (content-url (string-utf8 256)))
  (let (
    (new-id (var-get next-creator-id))
  )
    ;; Check if this principal already has a creator account
    (asserts! (is-none (map-get? principal-to-creator-id { owner: tx-sender })) ERR-ALREADY-EXISTS)
    
    ;; Create new creator profile
    (map-set creators
      { creator-id: new-id }
      {
        owner: tx-sender,
        name: name,
        description: description,
        content-url: content-url,
        creation-time: block-height,
        total-rewards: u0,
        subscriber-count: u0,
        verified: false
      }
    )
    
    ;; Map principal to creator ID
    (map-set principal-to-creator-id
      { owner: tx-sender }
      { creator-id: new-id }
    )
    
    ;; Initialize next perk ID for this creator
    (map-set next-perk-id
      { creator-id: new-id }
      { next-id: u1 }
    )
    
    ;; Increment next creator ID
    (var-set next-creator-id (+ new-id u1))
    
    (ok new-id)
  )
)

;; Update creator profile
(define-public (update-creator-profile 
                (creator-id uint) 
                (name (string-ascii 64)) 
                (description (string-utf8 500)) 
                (content-url (string-utf8 256)))
  (begin
    ;; Check authorization
    (asserts! (is-creator-owner creator-id) ERR-NOT-AUTHORIZED)
    
    ;; Get current profile
    (match (map-get? creators { creator-id: creator-id })
      profile (map-set creators
                { creator-id: creator-id }
                (merge profile {
                  name: name,
                  description: description,
                  content-url: content-url
                })
              )
      (err ERR-NOT-FOUND)
    )
    
    (ok true)
  )
)

;; Send a one-time tip to a creator
(define-public (tip-creator 
                (creator-id uint) 
                (amount uint) 
                (message (optional (string-utf8 280)))
                (anonymous bool))
  (begin
    ;; Check if creator exists
    (asserts! (is-some (map-get? creators { creator-id: creator-id })) ERR-NOT-FOUND)
    
    ;; Check minimum tip amount
    (asserts! (>= amount MIN-TIP-AMOUNT) ERR-INVALID-AMOUNT)
    
    ;; Transfer funds with fee
    (asserts! (transfer-with-fee creator-id amount) ERR-INSUFFICIENT-FUNDS)
    
    ;; Record the reward
    (record-reward creator-id amount "tip" message anonymous)
    
    (ok true)
  )
)

;; Add a subscription tier
(define-public (add-subscription-tier 
                (creator-id uint) 
                (tier-id uint) 
                (name (string-ascii 64))
                (price uint)
                (duration-days uint)
                (description (string-utf8 500)))
  (begin
    ;; Check authorization
    (asserts! (is-creator-owner creator-id) ERR-NOT-AUTHORIZED)
    
    ;; Validate parameters
    (asserts! (> price u0) ERR-INVALID-AMOUNT)
    (asserts! (> duration-days u0) ERR-INVALID-AMOUNT)
    
    ;; Add the subscription tier
    (map-set subscription-tiers
      { creator-id: creator-id, tier-id: tier-id }
      {
        name: name,
        price: price,
        duration-days: duration-days,
        description: description
      }
    )
    
    (ok true)
  )
)

;; Subscribe to a creator
(define-public (subscribe
                (creator-id uint)
                (tier-id uint)
                (auto-renew bool)
                (message (optional (string-utf8 280)))
                (anonymous bool))
  (let (
    (tier (unwrap! (map-get? subscription-tiers { creator-id: creator-id, tier-id: tier-id }) ERR-INVALID-SUBSCRIPTION))
    (duration-blocks (* (get duration-days tier) u144)) ;; ~144 blocks per day
    (price (get price tier))
    (creator-profile (unwrap! (map-get? creators { creator-id: creator-id }) ERR-NOT-FOUND))
  )
    ;; Transfer funds with fee
    (asserts! (transfer-with-fee creator-id price) ERR-INSUFFICIENT-FUNDS)
    
    ;; Record the reward
    (record-reward creator-id price "subscription" message anonymous)
    
    ;; Update subscription status
    (match (map-get? subscriptions { supporter: tx-sender, creator-id: creator-id })
      existing-sub
        ;; Extend existing subscription if not expired
        (if (> (get end-time existing-sub) block-height)
          (map-set subscriptions
            { supporter: tx-sender, creator-id: creator-id }
            {
              tier-id: tier-id,
              start-time: (get start-time existing-sub),
              end-time: (+ (get end-time existing-sub) duration-blocks),
              auto-renew: auto-renew
            }
          )
          ;; Otherwise create new subscription
          (map-set subscriptions
            { supporter: tx-sender, creator-id: creator-id }
            {
              tier-id: tier-id,
              start-time: block-height,
              end-time: (+ block-height duration-blocks),
              auto-renew: auto-renew
            }
          )
        )
      ;; New subscription
      (begin
        ;; Increment subscriber count
        (map-set creators
          { creator-id: creator-id }
          (merge creator-profile { subscriber-count: (+ (get subscriber-count creator-profile) u1) })
        )
        
        ;; Create subscription
        (map-set subscriptions
          { supporter: tx-sender, creator-id: creator-id }
          {
            tier-id: tier-id,
            start-time: block-height,
            end-time: (+ block-height duration-blocks),
            auto-renew: auto-renew
          }
        )
      )
    )
    
    (ok true)
  )
)

;; Cancel subscription
(define-public (cancel-subscription (creator-id uint))
  (match (map-get? subscriptions { supporter: tx-sender, creator-id: creator-id })
    subscription 
      (begin
        (map-set subscriptions
          { supporter: tx-sender, creator-id: creator-id }
          (merge subscription { auto-renew: false })
        )
        (ok true)
      )
    (err ERR-NOT-FOUND)
  )
)

;; Add a special perk
(define-public (add-perk 
                (creator-id uint) 
                (name (string-ascii 64))
                (price uint)
                (description (string-utf8 500))
                (available-count (optional uint)))
  (let (
    (next-id (unwrap! (map-get? next-perk-id { creator-id: creator-id }) ERR-NOT-FOUND))
    (perk-id (get next-id next-id))
  )
    ;; Check authorization
    (asserts! (is-creator-owner creator-id) ERR-NOT-AUTHORIZED)
    
    ;; Validate price
    (asserts! (> price u0) ERR-INVALID-AMOUNT)
    
    ;; Add the perk
    (map-set perks
      { creator-id: creator-id, perk-id: perk-id }
      {
        name: name,
        price: price,
        description: description,
        available-count: available-count,
        sold-count: u0
      }
    )
    
    ;; Update next perk ID
    (map-set next-perk-id
      { creator-id: creator-id }
      { next-id: (+ perk-id u1) }
    )
    
    (ok perk-id)
  )
)

;; Purchase a perk
(define-public (purchase-perk 
                (creator-id uint) 
                (perk-id uint)
                (message (optional (string-utf8 280)))
                (anonymous bool))
  (let (
    (perk (unwrap! (map-get? perks { creator-id: creator-id, perk-id: perk-id }) ERR-INVALID-PERK))
    (price (get price perk))
    (available-count (get available-count perk))
    (sold-count (get sold-count perk))
  )
    ;; Check if perk is still available
    (match available-count
      limit (asserts! (< sold-count limit) ERR-INVALID-PERK)
      true ;; No limit
    )
    
    ;; Transfer funds with fee
    (asserts! (transfer-with-fee creator-id price) ERR-INSUFFICIENT-FUNDS)
    
    ;; Record the reward
    (record-reward creator-id price "perk" message anonymous)
    
    ;; Update sold count
    (map-set perks
      { creator-id: creator-id, perk-id: perk-id }
      (merge perk { sold-count: (+ sold-count u1) })
    )
    
    (ok true)
  )
)

;; Platform admin functions

;; Update platform fee percentage (only callable by platform wallet)
(define-public (set-platform-fee (new-fee-percentage uint))
  (begin
    (asserts! (is-eq tx-sender (var-get platform-wallet)) ERR-PLATFORM-ONLY)
    (asserts! (<= new-fee-percentage u30) ERR-INVALID-AMOUNT) ;; Max 30% fee
    (var-set platform-fee-percentage new-fee-percentage)
    (ok true)
  )
)

;; Update platform wallet address (only callable by current platform wallet)
(define-public (set-platform-wallet (new-wallet principal))
  (begin
    (asserts! (is-eq tx-sender (var-get platform-wallet)) ERR-PLATFORM-ONLY)
    (var-set platform-wallet new-wallet)
    (ok true)
  )
)

;; Verify a creator (only callable by platform wallet)
(define-public (verify-creator (creator-id uint) (verified bool))
  (begin
    (asserts! (is-eq tx-sender (var-get platform-wallet)) ERR-PLATFORM-ONLY)
    (match (map-get? creators { creator-id: creator-id })
      profile (map-set creators
                { creator-id: creator-id }
                (merge profile { verified: verified })
              )
      (err ERR-NOT-FOUND)
    )
    (ok true)
  )
)