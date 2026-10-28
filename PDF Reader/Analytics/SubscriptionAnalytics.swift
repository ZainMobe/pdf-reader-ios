import Foundation
import RevenueCat

enum SubscriptionAnalytics {
    private static let knownKey = "analytics.sub.known"
    private static let activeKey = "analytics.sub.active"
    private static let willRenewKey = "analytics.sub.willRenew"
    private static let billingIssueKey = "analytics.sub.billingIssue"
    private static let periodKey = "analytics.sub.period"
    private static let productKey = "analytics.sub.product"

    static func observe(_ info: CustomerInfo) {
        let defaults = UserDefaults.standard
        let entitlement = info.entitlements[RevenueCatConstants.proEntitlementID]
        let active = entitlement?.isActive == true
        let willRenew = entitlement?.willRenew == true
        let billingIssue = active && entitlement?.billingIssueDetectedAt != nil
        let period = entitlement.map { periodName($0.periodType) } ?? "none"
        let product = entitlement?.productIdentifier ?? ""

        if defaults.bool(forKey: knownKey) {
            let wasActive = defaults.bool(forKey: activeKey)
            let wasRenewing = defaults.bool(forKey: willRenewKey)
            let hadBillingIssue = defaults.bool(forKey: billingIssueKey)
            let previousPeriod = defaults.string(forKey: periodKey) ?? "none"
            let previousProduct = defaults.string(forKey: productKey)
            let plan = AnalyticsUserProperties.planName(for: product.isEmpty ? previousProduct : product, isPro: true)
            let isLifetime = plan == "lifetime"

            if wasActive && !active {
                AppAnalytics.log(.subscriptionExpired, [
                    .plan: AnalyticsUserProperties.planName(for: previousProduct, isPro: true),
                    .periodType: previousPeriod,
                    .kind: hadBillingIssue ? "billing_issue" : "not_renewed",
                ])
            } else if active && wasActive && wasRenewing && !willRenew && !isLifetime {
                AppAnalytics.log(.subscriptionCancelled, [.plan: plan, .periodType: period])
            } else if active && wasActive && !wasRenewing && willRenew && !isLifetime {
                AppAnalytics.log(.subscriptionReactivated, [.plan: plan, .periodType: period])
            }
            if billingIssue && !hadBillingIssue {
                AppAnalytics.log(.subscriptionBillingIssue, [.plan: plan, .periodType: period])
            }
            if active && wasActive && previousPeriod == "trial" && period == "normal" {
                AppAnalytics.log(.trialConverted, [.plan: plan])
            }
        }

        defaults.set(true, forKey: knownKey)
        defaults.set(active, forKey: activeKey)
        defaults.set(willRenew, forKey: willRenewKey)
        defaults.set(billingIssue, forKey: billingIssueKey)
        defaults.set(period, forKey: periodKey)
        if !product.isEmpty { defaults.set(product, forKey: productKey) }

        let state: String
        if !active {
            state = (defaults.string(forKey: productKey) ?? "").isEmpty ? "never" : "lapsed"
        } else if billingIssue {
            state = "billing_issue"
        } else if entitlement?.periodType == .trial {
            state = willRenew ? "trial" : "trial_cancelled"
        } else if AnalyticsUserProperties.planName(for: product, isPro: true) == "lifetime" {
            state = "lifetime"
        } else {
            state = willRenew ? "active" : "cancelled"
        }
        AppAnalytics.setUserProperty(.subscriptionState, state)
    }

    private static func periodName(_ type: PeriodType) -> String {
        switch type {
        case .normal: "normal"
        case .intro: "intro"
        case .trial: "trial"
        case .prepaid: "prepaid"
        @unknown default: "other"
        }
    }
}
