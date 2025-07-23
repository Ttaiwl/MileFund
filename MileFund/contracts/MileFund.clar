;; MileFund: Milestone-based Crowdfunding Contract
;; Description: A decentralized crowdfunding platform with milestone validation and community governance

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INVALID_CAMPAIGN (err u101))
(define-constant ERR_CAMPAIGN_EXISTS (err u102))
(define-constant ERR_INSUFFICIENT_FUNDS (err u103))
(define-constant ERR_MILESTONE_NOT_FOUND (err u104))
(define-constant ERR_INVALID_MILESTONE_STATE (err u105))
(define-constant ERR_CAMPAIGN_ENDED (err u106))
(define-constant ERR_ALREADY_WITHDRAWN (err u107))
(define-constant ERR_INVALID_INPUT (err u108))

;; Data Storage
(define-map funding-campaigns
    { campaign-id: uint }
    {
        project-creator: principal,
        project-title: (string-ascii 64),
        project-description: (string-ascii 256),
        target-amount: uint,
        deadline-block: uint,
        raised-amount: uint,
        is-active: bool,
        total-withdrawn: uint
    }
)

(define-map project-milestones
    { campaign-id: uint, milestone-id: uint }
    {
        milestone-description: (string-ascii 256),
        required-funds: uint,
        completion-deadline: uint,
        is-completed: bool,
        approval-threshold: uint,
        approval-count: uint,
        funds-released: bool
    }
)

(define-map backer-contributions
    { campaign-id: uint, backer: principal }
    { contribution-amount: uint }
)

(define-map milestone-approvals
    { campaign-id: uint, milestone-id: uint, approver: principal }
    { has-approved: bool }
)

;; Campaign ID Counter
(define-data-var next-campaign-id uint u0)

;; Input Validation Helpers
(define-private (is-valid-string (input (string-ascii 256)))
    (> (len input) u0)
)

(define-private (is-valid-amount (amount uint))
    (> amount u0)
)

(define-private (campaign-exists (campaign-id uint))
    (is-some (map-get? funding-campaigns { campaign-id: campaign-id }))
)

(define-private (milestone-exists (campaign-id uint) (milestone-id uint))
    (is-some (map-get? project-milestones { campaign-id: campaign-id, milestone-id: milestone-id }))
)

;; Core Campaign Functions
(define-public (launch-campaign (project-title (string-ascii 64)) 
                               (project-description (string-ascii 256))
                               (target-amount uint)
                               (campaign-duration uint))
    (let
        (
            (new-campaign-id (+ (var-get next-campaign-id) u1))
            (deadline-block (+ block-height campaign-duration))
        )
        ;; Input validation
        (asserts! (is-valid-string project-title) ERR_INVALID_INPUT)
        (asserts! (is-valid-string project-description) ERR_INVALID_INPUT)
        (asserts! (is-valid-amount target-amount) ERR_INVALID_INPUT)
        (asserts! (is-valid-amount campaign-duration) ERR_INVALID_INPUT)
        
        (map-set funding-campaigns
            { campaign-id: new-campaign-id }
            {
                project-creator: tx-sender,
                project-title: project-title,
                project-description: project-description,
                target-amount: target-amount,
                deadline-block: deadline-block,
                raised-amount: u0,
                is-active: true,
                total-withdrawn: u0
            }
        )
        
        (var-set next-campaign-id new-campaign-id)
        (ok new-campaign-id)
    )
)

(define-public (create-milestone (campaign-id uint)
                                (milestone-description (string-ascii 256))
                                (required-funds uint)
                                (completion-deadline uint)
                                (approval-threshold uint))
    (let
        (
            (campaign-data (unwrap! (map-get? funding-campaigns { campaign-id: campaign-id }) ERR_INVALID_CAMPAIGN))
        )
        ;; Input validation
        (asserts! (campaign-exists campaign-id) ERR_INVALID_CAMPAIGN)
        (asserts! (is-valid-string milestone-description) ERR_INVALID_INPUT)
        (asserts! (is-valid-amount required-funds) ERR_INVALID_INPUT)
        (asserts! (is-valid-amount completion-deadline) ERR_INVALID_INPUT)
        (asserts! (is-valid-amount approval-threshold) ERR_INVALID_INPUT)
        (asserts! (is-eq (get project-creator campaign-data) tx-sender) ERR_NOT_AUTHORIZED)
        (asserts! (get is-active campaign-data) ERR_CAMPAIGN_ENDED)
        
        (map-set project-milestones
            { campaign-id: campaign-id, milestone-id: u0 }
            {
                milestone-description: milestone-description,
                required-funds: required-funds,
                completion-deadline: completion-deadline,
                is-completed: false,
                approval-threshold: approval-threshold,
                approval-count: u0,
                funds-released: false
            }
        )
        (ok true)
    )
)

;; Funding Operations
(define-public (back-campaign (campaign-id uint) (contribution-amount uint))
    (let
        (
            (campaign-data (unwrap! (map-get? funding-campaigns { campaign-id: campaign-id }) ERR_INVALID_CAMPAIGN))
            (existing-contribution (default-to u0 (get contribution-amount (map-get? backer-contributions { campaign-id: campaign-id, backer: tx-sender }))))
        )
        ;; Input validation
        (asserts! (campaign-exists campaign-id) ERR_INVALID_CAMPAIGN)
        (asserts! (is-valid-amount contribution-amount) ERR_INVALID_INPUT)
        (asserts! (get is-active campaign-data) ERR_CAMPAIGN_ENDED)
        (asserts! (<= block-height (get deadline-block campaign-data)) ERR_CAMPAIGN_ENDED)
        
        ;; Transfer STX from backer to contract
        (try! (stx-transfer? contribution-amount tx-sender (as-contract tx-sender)))
        
        ;; Update campaign raised amount
        (map-set funding-campaigns
            { campaign-id: campaign-id }
            (merge campaign-data { raised-amount: (+ (get raised-amount campaign-data) contribution-amount) })
        )
        
        ;; Update backer contribution record
        (map-set backer-contributions
            { campaign-id: campaign-id, backer: tx-sender }
            { contribution-amount: (+ existing-contribution contribution-amount) }
        )
        
        (ok true)
    )
)

;; Milestone Fund Release
(define-public (release-milestone-funds (campaign-id uint) (milestone-id uint))
    (let
        (
            (campaign-data (unwrap! (map-get? funding-campaigns { campaign-id: campaign-id }) ERR_INVALID_CAMPAIGN))
            (milestone-data (unwrap! (map-get? project-milestones { campaign-id: campaign-id, milestone-id: milestone-id }) ERR_MILESTONE_NOT_FOUND))
        )
        ;; Input validation
        (asserts! (campaign-exists campaign-id) ERR_INVALID_CAMPAIGN)
        (asserts! (milestone-exists campaign-id milestone-id) ERR_MILESTONE_NOT_FOUND)
        ;; Verify caller is project creator
        (asserts! (is-eq (get project-creator campaign-data) tx-sender) ERR_NOT_AUTHORIZED)
        ;; Verify milestone is completed
        (asserts! (get is-completed milestone-data) ERR_INVALID_MILESTONE_STATE)
        ;; Verify funds haven't been released yet
        (asserts! (not (get funds-released milestone-data)) ERR_ALREADY_WITHDRAWN)
        
        ;; Calculate withdrawal amount
        (let
            (
                (withdrawal-amount (get required-funds milestone-data))
                (new-total-withdrawn (+ (get total-withdrawn campaign-data) withdrawal-amount))
            )
            ;; Verify sufficient funds available
            (asserts! (<= new-total-withdrawn (get raised-amount campaign-data)) ERR_INSUFFICIENT_FUNDS)
            
            ;; Transfer funds to project creator
            (try! (as-contract (stx-transfer? withdrawal-amount tx-sender (get project-creator campaign-data))))
            
            ;; Update milestone release status
            (map-set project-milestones
                { campaign-id: campaign-id, milestone-id: milestone-id }
                (merge milestone-data { funds-released: true })
            )
            
            ;; Update campaign withdrawal total
            (map-set funding-campaigns
                { campaign-id: campaign-id }
                (merge campaign-data { total-withdrawn: new-total-withdrawn })
            )
            
            (ok withdrawal-amount)
        )
    )
)

;; Community Validation System
(define-public (approve-milestone (campaign-id uint) (milestone-id uint))
    (let
        (
            (milestone-data (unwrap! (map-get? project-milestones { campaign-id: campaign-id, milestone-id: milestone-id }) ERR_MILESTONE_NOT_FOUND))
            (campaign-data (unwrap! (map-get? funding-campaigns { campaign-id: campaign-id }) ERR_INVALID_CAMPAIGN))
            (has-backed (> (default-to u0 (get contribution-amount (map-get? backer-contributions { campaign-id: campaign-id, backer: tx-sender }))) u0))
        )
        ;; Input validation
        (asserts! (campaign-exists campaign-id) ERR_INVALID_CAMPAIGN)
        (asserts! (milestone-exists campaign-id milestone-id) ERR_MILESTONE_NOT_FOUND)
        (asserts! has-backed ERR_NOT_AUTHORIZED)
        (asserts! (not (get is-completed milestone-data)) ERR_INVALID_MILESTONE_STATE)
        (asserts! (not (default-to false (get has-approved (map-get? milestone-approvals { campaign-id: campaign-id, milestone-id: milestone-id, approver: tx-sender })))) ERR_NOT_AUTHORIZED)
        
        ;; Record approval
        (map-set milestone-approvals
            { campaign-id: campaign-id, milestone-id: milestone-id, approver: tx-sender }
            { has-approved: true }
        )
        
        ;; Update milestone approval count
        (map-set project-milestones
            { campaign-id: campaign-id, milestone-id: milestone-id }
            (merge milestone-data { approval-count: (+ (get approval-count milestone-data) u1) })
        )
        
        ;; Check if milestone reaches approval threshold
        (if (>= (+ (get approval-count milestone-data) u1) (get approval-threshold milestone-data))
            (begin
                ;; Mark milestone as completed
                (map-set project-milestones
                    { campaign-id: campaign-id, milestone-id: milestone-id }
                    (merge milestone-data { 
                        is-completed: true,
                        approval-count: (+ (get approval-count milestone-data) u1)
                    })
                )
                (ok true)
            )
            (ok true)
        )
    )
)

;; Refund Mechanism
(define-public (request-refund (campaign-id uint))
    (let
        (
            (campaign-data (unwrap! (map-get? funding-campaigns { campaign-id: campaign-id }) ERR_INVALID_CAMPAIGN))
            (backer-amount (unwrap! (get contribution-amount (map-get? backer-contributions { campaign-id: campaign-id, backer: tx-sender })) ERR_INSUFFICIENT_FUNDS))
        )
        ;; Input validation
        (asserts! (campaign-exists campaign-id) ERR_INVALID_CAMPAIGN)
        (asserts! (> block-height (get deadline-block campaign-data)) ERR_INVALID_CAMPAIGN)
        (asserts! (< (get raised-amount campaign-data) (get target-amount campaign-data)) ERR_INVALID_CAMPAIGN)
        
        ;; Process refund
        (try! (as-contract (stx-transfer? backer-amount tx-sender tx-sender)))
        
        ;; Remove backer record
        (map-delete backer-contributions { campaign-id: campaign-id, backer: tx-sender })
        
        ;; Update campaign raised amount
        (map-set funding-campaigns
            { campaign-id: campaign-id }
            (merge campaign-data { raised-amount: (- (get raised-amount campaign-data) backer-amount) })
        )
        
        (ok true)
    )
)

;; Read-only Query Functions
(define-read-only (get-campaign-details (campaign-id uint))
    (map-get? funding-campaigns { campaign-id: campaign-id })
)

(define-read-only (get-milestone-details (campaign-id uint) (milestone-id uint))
    (map-get? project-milestones { campaign-id: campaign-id, milestone-id: milestone-id })
)

(define-read-only (get-backer-contribution (campaign-id uint) (backer principal))
    (map-get? backer-contributions { campaign-id: campaign-id, backer: backer })
)