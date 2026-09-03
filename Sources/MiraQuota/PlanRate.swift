import Foundation

/// 额度点的官方美元口径。
///
/// Mirasim 公布的套餐额度以美元计：MAX 40X 的 7 天额度为 $5600，同一账号 `/v1/limits` 的
/// 7d 预算点为 560000，故 1 点 = $0.01；各档位的预算点按同一比例缩放（MAX 10X 为 140000 点）。
/// 内测账号（`paid == false`）额度减半，折成每点 $0.005。
///
/// 本机账本反推的 Opus 用量为 204 点/美元（2026-09-02 实测），与该口径相差 2%；Fable 5.1 按价目 2 倍扣点
/// （见 `Pricing`），账本按 API 价目折算，Fable 占比高时账本反推的每点美元低于本口径。
/// 本口径是 Mirasim 扣点单位的美元值，与账本不同口径，不进面板；面板满额由账本标定给出，
/// 本口径只在 `--doctor` 的「官方口径 / 官方满额」两行作对照。
enum PlanRate {
    /// 名义每点美元。
    static let nominalUSDPerPoint = 0.01
    /// 内测账号的额度系数。
    static let betaFactor = 0.5

    /// 端点未给出 `paid` 时为 nil，上层退回账本标定。
    static func usdPerPoint(paid: Bool?) -> Double? {
        guard let paid else { return nil }
        return nominalUSDPerPoint * (paid ? 1 : betaFactor)
    }

    static func note(paid: Bool) -> String {
        paid ? "官方口径 $0.01/点" : "官方口径 $0.01/点 × 内测 ½"
    }
}
