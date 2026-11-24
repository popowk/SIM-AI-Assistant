import Foundation

/// Deterministic, intentionally narrow telephone receptionist. No LLM,
/// external knowledge, payments, verification codes, or commitments.
public struct LocalReceptionPolicy {
    public enum Reply: String, CaseIterable {
        case greeting, purpose, delivery, business, callback, noted, repeatPlease, goodbye, noSensitive
        case consentRecording, consentWebhook, consentBoth, consentAccepted, consentDeclined
        public var text: String {
            switch self {
            case .greeting: return "您好，我是王先生的AI电话助理，本次通话由本地语音程序处理。请问您有什么事情？"
            case .consentRecording: return "您好，我是王先生的AI电话助理。是否同意本次通话在本机录音？请说同意或不同意。"
            case .consentWebhook: return "您好，我是王先生的AI电话助理。是否同意将本次通话识别文字发送给王先生的飞书机器人？请说同意或不同意。"
            case .consentBoth: return "您好，我是王先生的AI电话助理。是否同意本机录音并将识别文字发送给王先生的飞书机器人？请说同意或不同意。"
            case .consentAccepted: return "好的，请问您有什么事情？"
            case .consentDeclined: return "好的，不录音也不转发文字。请问您有什么事情？"
            case .purpose: return "请问您找王先生具体有什么事情？"
            case .delivery: return "好的，请说明是什么物品，是否需要本人处理？"
            case .business: return "好的，请简单说明您的需求和需要转达的事项。"
            case .callback: return "好的，请问怎么称呼您，需要转达什么事情？"
            case .noted: return "好的，您的事项已在本次接待中记录。请问还有别的事情吗？"
            case .repeatPlease: return "不好意思，请您再简单说一下来电目的。"
            case .goodbye: return "好的，感谢您的来电，再见。"
            case .noSensitive: return "请不要提供验证码、密码或支付信息。您可以直接联系本人确认。"
            }
        }
    }
    public private(set) var awaitingDetails = false
    public init() {}
    public mutating func reply(to input: String) -> Reply {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return .repeatPlease }
        func contains(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
        if contains(["验证码","密码","转账","银行卡","支付密码"]) {
            awaitingDetails = false
            return .noSensitive
        }
        if contains(["再见","拜拜","没别的事","没有别的事","先这样","没事了","不用了","没有了"]) {
            awaitingDetails = false
            return .goodbye
        }
        if awaitingDetails {
            if s.count < 3 { return .repeatPlease }
            awaitingDetails = false
            return .noted
        }
        if contains(["快递","外卖","送货","配送","取件","签收"]) {
            awaitingDetails = true; return .delivery
        }
        if contains(["回电话","回个电话","回电","联系我","给我打电话"]) {
            awaitingDetails = true; return .callback
        }
        if contains(["产品","客户","合作","售后","咨询","报价","订单","业务","维修","安装"]) {
            awaitingDetails = true; return .business
        }
        if contains(["在吗","在不在","找王","王先生","王总","本人","你好","您好","喂"]) && s.count <= 12 {
            return .purpose
        }
        if s.count < 4 { return .repeatPlease }
        awaitingDetails = false
        return .noted
    }
}

/// Strict opt-in. Unknown or negative answers never authorize persistence or forwarding.
public enum LocalCaptureConsent {
    public static func accepts(_ text: String) -> Bool {
        let clean = text.replacingOccurrences(of: "[\\s，。！？、,.!?]", with: "", options: .regularExpression)
        if ["不","别","拒绝","取消","停止","没同意"].contains(where: { clean.contains($0) }) { return false }
        return ["同意","我同意","好的同意","可以录音","同意录音","同意转发","同意录音和转发","同意录音并转发","同意录音和发送文字"].contains(clean)
    }
    public static func revokes(_ text: String) -> Bool {
        ["停止录音","不要录音","别录音","取消录音","不同意录音","不要转发","停止转发","取消转发","不要发送文字","撤回同意"].contains(where: { text.contains($0) })
    }
}
