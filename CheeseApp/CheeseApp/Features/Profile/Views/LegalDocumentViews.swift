import SwiftUI

enum LegalDocument: String, Identifiable {
    case communityRules
    case privacyPolicy
    case userAgreement
    case acknowledgements

    var id: String { rawValue }

    var title: String {
        switch self {
        case .communityRules: L10n.tr("Community Rules", "社群规则")
        case .privacyPolicy: L10n.tr("Privacy Policy", "隐私政策")
        case .userAgreement: L10n.tr("User Agreement", "用户协议")
        case .acknowledgements: L10n.tr("Acknowledgements", "致谢")
        }
    }

    var subtitle: String {
        switch self {
        case .communityRules:
            L10n.tr("The shared rules for a safe, useful campus community", "共同维护安全、有用的校园社群")
        case .privacyPolicy:
            L10n.tr("How Cheese collects, uses and protects information", "Cheese 如何搜集、使用与保护资料")
        case .userAgreement:
            L10n.tr("The terms that apply when you use Cheese", "使用 Cheese 时适用的基本约定")
        case .acknowledgements:
            L10n.tr("Thanks to the people, communities and technology behind Cheese", "感谢成就 Cheese 的社群、伙伴与技术")
        }
    }

    var icon: String {
        switch self {
        case .communityRules: "shield.lefthalf.filled"
        case .privacyPolicy: "hand.raised.fill"
        case .userAgreement: "doc.text.fill"
        case .acknowledgements: "heart.text.square.fill"
        }
    }

    var sections: [LegalSection] {
        switch self {
        case .communityRules: Self.communityRuleSections
        case .privacyPolicy: Self.privacySections
        case .userAgreement: Self.agreementSections
        case .acknowledgements: Self.acknowledgementSections
        }
    }

    var links: [LegalReferenceLink] {
        guard self == .acknowledgements else { return [] }
        return [
            .init(
                title: .init("Dcard Community Guidelines", "Dcard 社群守则与规范"),
                destination: "https://support.dcard.in/hc/zh-tw/articles/14747742351631"
            ),
            .init(
                title: .init("Reddit Rules", "Reddit Rules 社群规则"),
                destination: "https://redditinc.com/policies/reddit-rules"
            ),
            .init(
                title: .init("Supabase Swift", "Supabase Swift"),
                destination: "https://github.com/supabase/supabase-swift"
            ),
            .init(
                title: .init("Swift open-source projects", "Swift 开源专案"),
                destination: "https://www.swift.org/community/"
            )
        ]
    }

    private static let communityRuleSections: [LegalSection] = [
        .init(
            title: .init("1. Be a constructive community member", "1. 做一个对社群有帮助的人"),
            paragraphs: [
                .init(
                    "Cheese is built for students to exchange experiences, housing and second-hand items, discuss courses and connect through chat. Disagreement is welcome; intimidation and abuse are not.",
                    "Cheese 让学生交流经验、租屋与二手物品、讨论课程并透过聊天建立连结。我们欢迎不同观点，但不接受恐吓、羞辱或滥用。"
                )
            ],
            bullets: [
                .init("Discuss ideas and conduct, not a person's inherent identity.", "针对观点与行为讨论，不攻击他人的身分与人格。"),
                .init("Use clear titles, the right category and information that helps others understand the context.", "使用清楚标题、正确分类及足以理解情境的资讯。"),
                .init("Do not coordinate harassment, dogpiling or interference with another community.", "不得号召骚扰、围攻或干扰其他社群。")
            ]
        ),
        .init(
            title: .init("2. Protect safety and dignity", "2. 保护每个人的安全与尊严"),
            bullets: [
                .init("No threats, harassment, bullying, stalking, hate or discrimination based on protected or personal characteristics.", "不得威胁、骚扰、霸凌、跟踪，或基于族裔、国籍、性别、性倾向、宗教、身心状况等特征仇恨或歧视。"),
                .init("No encouragement or glorification of suicide, self-harm, violence or dangerous challenges. Supportive discussion and help-seeking resources are allowed.", "不得鼓励或美化自杀、自伤、暴力或危险挑战；善意讨论与寻求协助不在此限。"),
                .init("No sexual exploitation, non-consensual intimate content, sexual harassment, or any sexual content involving minors.", "不得发布性剥削、未经同意的私密内容、性骚扰，或任何涉及未成年人的性内容。")
            ]
        ),
        .init(
            title: .init("3. Respect privacy and identity", "3. 尊重隐私与真实身分"),
            bullets: [
                .init("Do not reveal or solicit private information such as home addresses, schedules, identity documents, financial details or private contact information without permission.", "未经同意，不得揭露或索取住址、行程、身分证件、财务资料或私人联络方式等个资。"),
                .init("Do not impersonate another person, school, organization, moderator or Cheese staff.", "不得冒充他人、学校、组织、管理员或 Cheese 官方。"),
                .init("Anonymous posting hides your public profile on that post; it does not make you unaccountable to Cheese or the law.", "匿名发文只会在该贴文隐藏你的公开个人档案，不代表 Cheese 无法处理违规，也不免除法律责任。")
            ]
        ),
        .init(
            title: .init("4. Keep illegal and harmful activity off Cheese", "4. 禁止违法及有害活动"),
            bullets: [
                .init("Do not facilitate fraud, theft, violence, illegal drugs, weapons, gambling, document forgery or evasion of law enforcement.", "不得促成诈骗、窃盗、暴力、非法药物、武器、赌博、伪造证件或规避执法。"),
                .init("Do not distribute malware, phishing links, stolen credentials or instructions intended to compromise systems or accounts.", "不得散布恶意程式、钓鱼连结、窃取的帐号资料，或以入侵系统及帐号为目的的指引。"),
                .init("If someone is in immediate danger, contact local emergency services first; a Cheese report is not an emergency service.", "若有人面临即时危险，请先联络当地紧急服务；Cheese 检举功能不是紧急救援服务。")
            ]
        ),
        .init(
            title: .init("5. No spam or manipulation", "5. 禁止垃圾内容与操纵行为"),
            bullets: [
                .init("No repetitive promotion, unsolicited bulk messages, deceptive links or irrelevant keyword stuffing.", "不得重复宣传、群发未经请求的讯息、使用欺骗连结或堆砌无关关键字。"),
                .init("Do not buy, sell or coordinate likes, comments, reviews, followers or accounts.", "不得买卖或组织灌入按赞、留言、评价、追踪或帐号。"),
                .init("Do not use alternate accounts to evade blocks, restrictions or moderation decisions.", "不得使用分身帐号规避封锁、限制或管理处分。")
            ]
        ),
        .init(
            title: .init("6. Forum, course and professor discussions", "6. 论坛、课程与教授讨论"),
            bullets: [
                .init("Base reviews on genuine experience and distinguish fact from opinion or hearsay.", "评价应基于真实经验，并清楚区分事实、个人观点与转述。"),
                .init("Critique teaching, course structure or professional conduct without publishing private personal details or organizing retaliation.", "可评论教学、课程安排或专业行为，但不得公开私人资料或号召报复。"),
                .init("Do not share exam answers, confidential course materials or copyrighted files without authorization.", "不得未经授权分享考试答案、机密课程资料或受著作权保护的档案。")
            ]
        ),
        .init(
            title: .init("7. Housing and second-hand listings", "7. 租屋与二手交易"),
            bullets: [
                .init("Describe price, condition, availability, fees, defects and material terms accurately; update or remove unavailable listings.", "应如实说明价格、状况、可用时间、费用、瑕疵与重要条件，失效后请更新或移除刊登。"),
                .init("No counterfeit, stolen, recalled, regulated or otherwise prohibited goods and services.", "不得刊登仿冒、赃物、召回品、受管制或其他禁止交易的商品与服务。"),
                .init("Never pressure another user to send deposits, codes, identity documents or irreversible payments. Meet safely and verify before paying.", "不得施压他人交付订金、验证码、身分证件或不可逆付款；面交时注意安全，付款前先验证。"),
                .init("Housing offers must not contain unlawful discrimination or materially misleading property information.", "租屋刊登不得包含违法歧视或重大不实的房屋资讯。")
            ]
        ),
        .init(
            title: .init("8. Intellectual property", "8. 智慧财产权"),
            paragraphs: [
                .init(
                    "Only post material you created or are authorized to share. Give attribution where required and do not remove ownership marks to mislead others.",
                    "只发布你自行创作或获授权分享的内容；需要时请标示来源，不得移除权利标示以误导他人。"
                )
            ]
        ),
        .init(
            title: .init("9. Reporting and enforcement", "9. 检举与处置"),
            paragraphs: [
                .init(
                    "Use Report on posts or messages for suspected violations and use Block to control your own experience. Reports should be made in good faith; abusive or retaliatory reporting is itself a violation.",
                    "发现疑似违规时，请使用贴文或讯息内的「举报」；你也可以封锁用户来管理自己的体验。检举必须出于善意，恶意或报复性检举本身也属违规。"
                ),
                .init(
                    "Cheese may label, limit, hide or remove content; restrict features; suspend or deactivate accounts; preserve relevant evidence; and cooperate with lawful requests. We consider severity, context, history, intent and risk. We do not promise to pre-review every item or act solely because a report was submitted.",
                    "Cheese 可标示、限制、隐藏或移除内容，限制功能，暂停或注销帐号，保存必要证据，并配合法律要求。我们会考量严重程度、脉络、历史、意图与风险；我们不保证事前审查所有内容，也不会仅因收到检举就自动处分。"
                ),
                .init(
                    "If you believe a decision is wrong, contact support@cheeseapp.dev with the account and decision details. Repeated or severe violations may receive stronger action without prior warning.",
                    "若你认为处置有误，请寄信至 support@cheeseapp.dev，提供帐号与处置资讯。重复或严重违规可能在未事先警告下受到更严格处分。"
                )
            ]
        )
    ]

    private static let privacySections: [LegalSection] = [
        .init(
            title: .init("1. Scope and operator", "1. 适用范围与营运者"),
            paragraphs: [
                .init(
                    "This policy describes how Cheese handles personal information when you use the iOS app, community, marketplace, housing, course, profile, notification and chat features. Cheese is the service operator for this policy. Contact: support@cheeseapp.dev.",
                    "本政策说明你使用 Cheese iOS App、社群、二手、租屋、课程、个人档案、通知与聊天功能时，我们如何处理个人资料。本政策中的服务营运者为 Cheese；联络信箱：support@cheeseapp.dev。"
                )
            ]
        ),
        .init(
            title: .init("2. Information we collect", "2. 我们搜集的资料"),
            bullets: [
                .init("Account data: email address, account identifier, sign-in provider and authentication records from Apple, Google or our authentication provider.", "帐号资料：Email、帐号识别码，以及 Apple、Google 或验证服务提供者产生的登入与验证纪录。"),
                .init("Profile data: display name, avatar, school, bio, occupation and preferences you choose to provide.", "个人档案：显示名称、头像、学校、简介、职业及你选择提供的偏好。"),
                .init("Community activity: posts, listings, course reviews, comments, reactions, favourites, follows, blocks, searches, reports and feedback.", "社群活动：贴文、刊登、课程评价、留言、反应、收藏、追踪、封锁、搜寻、举报与回馈。"),
                .init("Messages: direct and group messages, shared media, membership, read state and conversation settings.", "通讯资料：私讯与群聊内容、分享的媒体、群组成员关系、已读状态与对话设定。"),
                .init("Technical data: IP address and request logs processed by our hosting provider, device or app version, push token, timestamps, security events, cache and basic diagnostic information.", "技术资料：由托管服务处理的 IP 位址与请求纪录、装置或 App 版本、推播权杖、时间戳记、安全事件、快取与基本诊断资讯。"),
                .init("Optional media: only photos you select through the system photo picker for an avatar, post, listing or message.", "选用媒体：仅包含你透过系统照片选择器主动选取并用于头像、贴文、刊登或讯息的照片。")
            ]
        ),
        .init(
            title: .init("3. How and why we use information", "3. 搜集方式与使用目的"),
            bullets: [
                .init("Provide accounts, profiles, posting, search, recommendations, chat, notifications and media delivery.", "提供帐号、个人档案、发布、搜寻、内容排序、聊天、通知与媒体传输功能。"),
                .init("Remember settings, maintain sessions, synchronize devices and improve reliability and usability.", "记住设定、维持登入、同步装置，并改善稳定性与易用性。"),
                .init("Prevent spam, fraud, abuse and security incidents; investigate reports and enforce our rules.", "预防垃圾内容、诈骗、滥用与安全事件；调查举报并执行社群规则。"),
                .init("Respond to support, protect users and comply with valid legal obligations.", "回应客服需求、保护用户，并履行有效的法律义务。")
            ]
        ),
        .init(
            title: .init("4. Public and anonymous activity", "4. 公开内容与匿名活动"),
            paragraphs: [
                .init(
                    "Profile fields and content posted to public areas may be viewed, copied, shared or captured by others. Anonymous posting hides the public link to your profile for that post, but Cheese still associates the activity with your account for security, operation and moderation. Do not publish information you want to remain private.",
                    "个人档案栏位及发布于公开区域的内容，可能被他人查看、复制、分享或截图。匿名发文只会隐藏该贴文与你公开档案的连结；基于营运、安全与管理需要，Cheese 仍会将该活动与你的帐号关联。请勿发布你希望保持私密的资讯。"
                )
            ]
        ),
        .init(
            title: .init("5. When information is shared", "5. 资料分享情形"),
            bullets: [
                .init("With other users according to the feature and visibility you select, including message recipients and group members.", "依功能与你选择的可见范围分享给其他用户，包括讯息接收者及群组成员。"),
                .init("With infrastructure and service providers needed to run Cheese, including Supabase for authentication, database, storage and realtime delivery; Apple and Google for sign-in; and Apple for push notifications.", "分享给维持 Cheese 所需的服务提供者，包括提供验证、资料库、储存与即时传输的 Supabase，提供登入的 Apple 与 Google，以及提供推播的 Apple。"),
                .init("With authorized reviewers when content is reported or access is necessary to address safety, fraud, support or rule enforcement.", "当内容遭举报，或为处理安全、诈骗、客服及规则执行所必要时，提供给经授权的审查人员。"),
                .init("When required by law, valid legal process, an emergency involving safety, or a business reorganization subject to appropriate safeguards.", "因法律、有效法律程序、涉及安全的紧急情况，或在具备适当保障的业务重组下提供。")
            ],
            footer: .init(
                "The current version of Cheese does not sell personal information or use cross-app tracking for targeted advertising.",
                "目前版本的 Cheese 不贩售个人资料，也不使用跨 App 追踪进行定向广告。"
            )
        ),
        .init(
            title: .init("6. Storage, retention and account deletion", "6. 储存、保留与帐号注销"),
            paragraphs: [
                .init(
                    "We retain information while your account is active and as reasonably necessary to provide the service, resolve disputes, prevent abuse and meet legal obligations. Retention varies by data type and context.",
                    "帐号有效期间内，我们会保留提供服务所需的资料；为解决争议、防止滥用及履行法律义务，也可能在合理必要期间内继续保留。实际期间依资料类型与情境而异。"
                ),
                .init(
                    "Using Delete Account removes your public posts and account activity covered by the deletion process, revokes sign-in identities and de-identifies the profile. A minimal tombstone remains so existing chats can show “Deactivated”. Messages already delivered, reports, security records, backups and copies retained by other users may remain where necessary or outside our control.",
                    "使用「注销帐号」后，系统会移除注销流程涵盖的公开贴文与帐号活动、撤销登入身分，并将个人档案去识别化。为让既有聊天显示「已注销」，系统会保留最小化的替代纪录；已送达的讯息、举报、安全纪录、备份，以及他人自行保存的副本，可能因必要性或超出我们控制而继续存在。"
                )
            ]
        ),
        .init(
            title: .init("7. Your choices and rights", "7. 你的选择与权利"),
            bullets: [
                .init("Edit profile information and choose whether eligible forum posts are anonymous.", "编辑个人档案，并选择符合条件的论坛贴文是否匿名。"),
                .init("Control push notifications, block users, hide messages for yourself and clear local image cache in Settings.", "在设定中控制推播、封锁用户、仅为自己隐藏讯息，并清除本机图片快取。"),
                .init("Delete your account from Settings.", "从设定中注销帐号。"),
                .init("Request access, correction, deletion, restriction or portability where applicable by emailing support@cheeseapp.dev. We may verify your identity first.", "在适用法律允许的范围内，可寄信至 support@cheeseapp.dev 请求查阅、更正、删除、限制处理或取得可携副本；我们可能先验证你的身分。")
            ]
        ),
        .init(
            title: .init("8. Children", "8. 未成年人"),
            paragraphs: [
                .init(
                    "Cheese is not for children under 13. If local law requires a higher minimum age or parental consent, that rule applies. Contact us if you believe a child provided information contrary to this requirement.",
                    "Cheese 不提供给未满 13 岁的儿童使用。若所在地法律要求更高的最低年龄或监护人同意，则以该规定为准。若你认为有儿童违反此要求提供资料，请联络我们。"
                )
            ]
        ),
        .init(
            title: .init("9. Security and international processing", "9. 安全与跨境处理"),
            paragraphs: [
                .init(
                    "We use access controls, row-level authorization, private media storage and other reasonable safeguards. No online service can guarantee absolute security. Service providers may process information outside your province or country, where different laws may apply.",
                    "我们使用存取控制、资料列层级授权、私人媒体储存及其他合理保障；但任何线上服务都无法保证绝对安全。服务提供者可能在你所在省份或国家以外处理资料，并受当地法律规范。"
                )
            ]
        ),
        .init(
            title: .init("10. Updates and contact", "10. 更新与联络方式"),
            paragraphs: [
                .init(
                    "We may update this policy as Cheese changes. Material changes will be communicated in the app or through another reasonable channel before they take effect where required. Questions or privacy requests: support@cheeseapp.dev.",
                    "我们可能随 Cheese 功能调整而更新本政策。若有重大变更，会在法律要求的情况下，于生效前透过 App 或其他合理方式通知。政策问题或隐私请求：support@cheeseapp.dev。"
                )
            ]
        )
    ]

    private static let agreementSections: [LegalSection] = [
        .init(
            title: .init("1. Accepting these terms", "1. 接受本协议"),
            paragraphs: [
                .init(
                    "By creating an account, accessing or using Cheese, you agree to this User Agreement, the Privacy Policy and Community Rules. If you do not agree, do not use the service. We may update these terms; continued use after an effective update means you accept the revised terms where permitted by law.",
                    "建立帐号、存取或使用 Cheese，即表示你同意本用户协议、隐私政策与社群规则；若不同意，请勿使用服务。我们可能更新条款；在法律允许范围内，变更生效后继续使用即表示接受新版条款。"
                )
            ]
        ),
        .init(
            title: .init("2. Eligibility", "2. 使用资格"),
            bullets: [
                .init("You must be at least 13 and meet any higher minimum age required where you live.", "你必须年满 13 岁，并符合所在地法律规定的更高最低年龄。"),
                .init("If you are under the age of majority, your parent or guardian must review and agree to these terms where required.", "若你未达法定成年年龄，所在地法律要求时，须由父母或监护人审阅并同意。"),
                .init("You must be legally permitted to use the service and not be subject to a continuing Cheese suspension.", "你必须依法可以使用本服务，且未处于 Cheese 的有效停权状态。")
            ]
        ),
        .init(
            title: .init("3. Account responsibility", "3. 帐号责任"),
            paragraphs: [
                .init(
                    "Provide accurate registration information, protect your sign-in credentials and promptly report unauthorized access. You are responsible for activity through your account unless caused by Cheese. You may not sell, rent, transfer or share an account to evade controls.",
                    "请提供正确的注册资料、妥善保护登入凭证，并立即回报未经授权的存取。除因 Cheese 所致外，你须对帐号内的活动负责。不得出售、出租、转让帐号，或共享帐号以规避限制。"
                )
            ]
        ),
        .init(
            title: .init("4. Your content and licence", "4. 你的内容与授权"),
            paragraphs: [
                .init(
                    "You retain ownership of content you create. You confirm that you have the rights and permissions needed to post it and that it does not violate law or another person's rights.",
                    "你保留自行创作内容的所有权；你确认拥有发布所需的权利与许可，且内容不违反法律或他人权利。"
                ),
                .init(
                    "You grant Cheese a worldwide, non-exclusive, royalty-free licence to host, store, reproduce, technically adapt, display, distribute and moderate your content only as reasonably necessary to operate, secure, improve and promote the Cheese service and its sharing features. This licence ends when content is deleted from active systems, except for reasonable backups, legal or safety retention, and copies already shared outside our control.",
                    "你授予 Cheese 全球性、非专属、免权利金的授权，使我们得在营运、保护、改善及推广 Cheese 与其分享功能的合理必要范围内，托管、储存、重制、进行技术格式调整、显示、散布及管理你的内容。内容从运作中系统删除后，此授权即终止；但合理备份、法律或安全保留，以及已分享且超出我们控制的副本除外。"
                )
            ]
        ),
        .init(
            title: .init("5. Acceptable use", "5. 合理使用"),
            paragraphs: [
                .init(
                    "Follow the Community Rules and all applicable laws. Do not misuse Cheese, interfere with service integrity, scrape or automate access without permission, bypass security or rate limits, reverse engineer except where law expressly permits, or use the service to harm others.",
                    "你必须遵守社群规则与适用法律。不得滥用 Cheese、干扰服务完整性、未经允许大量撷取或自动化存取、绕过安全与流量限制，或在法律未明确允许时进行逆向工程，也不得利用服务伤害他人。"
                )
            ]
        ),
        .init(
            title: .init("6. Anonymous posting", "6. 匿名发文"),
            paragraphs: [
                .init(
                    "Anonymous mode changes what other users see; it is not a guarantee of technical anonymity. Cheese may associate and review anonymous activity for operation, safety, moderation and legal compliance.",
                    "匿名模式只会改变其他用户看到的身分资讯，并不保证技术上的不可识别。Cheese 可基于营运、安全、管理及法律遵循，关联与审查匿名活动。"
                )
            ]
        ),
        .init(
            title: .init("7. Housing and marketplace transactions", "7. 租屋与二手交易"),
            paragraphs: [
                .init(
                    "Cheese provides listing and communication tools but is not the buyer, seller, landlord, tenant, broker, payment processor or party to user transactions. Users must verify identity, legality, condition, ownership, lease terms and payment safety. Cheese does not guarantee listings, users, transactions or outcomes and does not hold deposits or provide escrow unless a feature expressly says otherwise.",
                    "Cheese 提供刊登与联络工具，但不是用户交易中的买方、卖方、房东、租客、仲介、付款处理者或契约当事人。用户应自行核实身分、合法性、物品状况、所有权、租约条件与付款安全。除功能明确另有说明外，Cheese 不保证刊登、用户、交易或结果，也不保管订金或提供第三方托管。"
                )
            ]
        ),
        .init(
            title: .init("8. Courses and community information", "8. 课程与社群资讯"),
            paragraphs: [
                .init(
                    "Course information, professor ratings, posts and comments are informational and may be incomplete, subjective or outdated. They are not official academic, legal, financial, housing or safety advice. Confirm important decisions with the school or another qualified source.",
                    "课程资讯、教授评价、贴文与留言仅供参考，可能不完整、主观或已过时，并非官方学业、法律、财务、租屋或安全建议。重要决定请向学校或其他合格来源确认。"
                )
            ]
        ),
        .init(
            title: .init("9. Moderation and enforcement", "9. 内容管理与处置"),
            paragraphs: [
                .init(
                    "Cheese may investigate reports and, where reasonably necessary, label, limit, hide or remove content; restrict features; suspend or deactivate accounts; preserve evidence; and refer matters to appropriate authorities. We may act without advance notice in urgent or serious cases. Contact support@cheeseapp.dev to request review of a decision.",
                    "Cheese 可调查举报，并在合理必要时标示、限制、隐藏或移除内容，限制功能，暂停或注销帐号，保存证据，或将事项转交适当机关。遇紧急或严重情况时，我们可不经事先通知采取行动。如需申请覆核，请联络 support@cheeseapp.dev。"
                )
            ]
        ),
        .init(
            title: .init("10. Cheese and third-party rights", "10. Cheese 与第三方权利"),
            paragraphs: [
                .init(
                    "The app, branding, interface and original service materials are owned by Cheese or its licensors. Third-party content, school names and open-source components remain the property of their owners. These terms do not grant you rights to use their marks or materials beyond normal use of the service.",
                    "App、品牌、介面与原创服务素材由 Cheese 或授权人拥有；第三方内容、学校名称与开源元件仍属各权利人所有。本协议不授予你超出正常使用服务范围的商标或素材使用权。"
                )
            ]
        ),
        .init(
            title: .init("11. Service changes and availability", "11. 服务变更与可用性"),
            paragraphs: [
                .init(
                    "We may add, change, suspend or discontinue features and may impose reasonable usage limits. We aim for reliable service but do not promise uninterrupted, error-free or permanent availability. Third-party services may have separate terms and outages outside our control.",
                    "我们可能新增、变更、暂停或停止功能，并设定合理的使用限制。我们会努力维持可靠服务，但不保证不中断、完全无错或永久可用；第三方服务可能有自己的条款及超出我们控制的中断。"
                )
            ]
        ),
        .init(
            title: .init("12. Disclaimers and liability", "12. 免责与责任限制"),
            paragraphs: [
                .init(
                    "To the extent permitted by law, Cheese is provided “as is” and “as available” without implied warranties. Cheese does not endorse or guarantee user content, users, listings or transactions. You remain responsible for your interactions and decisions.",
                    "在法律允许范围内，Cheese 依『现状』及『可用状态』提供，不附默示保证。Cheese 不背书或保证用户内容、用户身分、刊登或交易；你须为自己的互动与决定负责。"
                ),
                .init(
                    "To the maximum extent permitted by law, Cheese is not liable for indirect, incidental, special, consequential or punitive loss, lost data, lost profits, or harm arising from user conduct or transactions. Nothing in these terms excludes rights or liability that cannot lawfully be excluded, including liability for our fraud, wilful misconduct or gross negligence where applicable.",
                    "在法律允许的最大范围内，Cheese 不对间接、附带、特殊、衍生或惩罚性损失、资料或利润损失，以及因用户行为或交易造成的损害负责。本条款不排除依法不得排除的权利或责任，包括适用时因我们的诈欺、故意不当行为或重大过失所生责任。"
                )
            ]
        ),
        .init(
            title: .init("13. Ending use", "13. 终止使用"),
            paragraphs: [
                .init(
                    "You may stop using Cheese or delete your account at any time. Provisions that by nature should survive—such as ownership, responsibility for prior conduct, disclaimers, liability limits and dispute terms—continue after termination.",
                    "你可随时停止使用 Cheese 或注销帐号。依性质应持续有效的条款，例如权利归属、先前行为责任、免责、责任限制与争议条款，在终止后仍然有效。"
                )
            ]
        ),
        .init(
            title: .init("14. Governing law and disputes", "14. 准据法与争议"),
            paragraphs: [
                .init(
                    "These terms are governed by the laws of Ontario and the federal laws of Canada applicable there, without limiting mandatory consumer rights in your jurisdiction. Before starting formal proceedings, please contact support@cheeseapp.dev so we can try to resolve the issue. Courts with lawful jurisdiction in Ontario may hear unresolved disputes unless mandatory law requires otherwise.",
                    "本协议以加拿大安大略省法律及在该省适用的加拿大联邦法律为准，但不限制你所在地不可排除的消费者权利。启动正式程序前，请先联络 support@cheeseapp.dev，让我们尝试解决问题；除强制法律另有规定外，未解决的争议可由安大略省具有合法管辖权的法院审理。"
                )
            ]
        ),
        .init(
            title: .init("15. Contact", "15. 联络方式"),
            paragraphs: [
                .init("Questions about these terms: support@cheeseapp.dev.", "如对本协议有疑问，请联络 support@cheeseapp.dev。")
            ]
        )
    ]

    private static let acknowledgementSections: [LegalSection] = [
        .init(
            title: .init("Our community", "我们的社群"),
            paragraphs: [
                .init(
                    "Cheese exists because students share honest experiences, help neighbours, report problems and suggest improvements. Thank you to every member who contributes thoughtfully and helps keep the community safe.",
                    "Cheese 因学生愿意分享真实经验、帮助身边的人、回报问题与提出改进建议而存在。感谢每一位用心参与并共同维护社群安全的成员。"
                )
            ]
        ),
        .init(
            title: .init("Community design references", "社群设计参考"),
            paragraphs: [
                .init(
                    "Our rule structure and plain-language approach were informed by public community-safety practices from Dcard and Reddit, then rewritten for Cheese's campus, course, housing, marketplace and chat features. Cheese is independent and is not affiliated with, sponsored by or endorsed by Dcard or Reddit.",
                    "本 App 的规则架构与白话表达，参考了 Dcard 与 Reddit 公开的社群安全实务，再依 Cheese 的校园、课程、租屋、二手与聊天功能重新撰写。Cheese 为独立服务，与 Dcard 或 Reddit 没有隶属、赞助或背书关系。"
                )
            ]
        ),
        .init(
            title: .init("Technology", "技术"),
            paragraphs: [
                .init(
                    "Cheese is built with Swift, SwiftUI and Apple platform frameworks. Authentication, database, storage and realtime capabilities use Supabase and its Swift libraries.",
                    "Cheese 使用 Swift、SwiftUI 与 Apple 平台框架建置；验证、资料库、储存与即时功能使用 Supabase 及其 Swift 函式库。"
                )
            ],
            bullets: [
                .init("Supabase Swift", "Supabase Swift"),
                .init("Apple Swift Crypto, Swift ASN.1 and Swift HTTP Types", "Apple Swift Crypto、Swift ASN.1 与 Swift HTTP Types"),
                .init("Point-Free Swift Clocks and Swift Concurrency Extras", "Point-Free Swift Clocks 与 Swift Concurrency Extras"),
                .init("XCTest Dynamic Overlay", "XCTest Dynamic Overlay")
            ]
        ),
        .init(
            title: .init("Licences and trademarks", "授权与商标"),
            paragraphs: [
                .init(
                    "Open-source components are used under their respective licences; copyright notices and licence terms remain with their authors. Apple, Google, Supabase, Dcard, Reddit, school names and other third-party marks belong to their respective owners. Mention does not imply endorsement.",
                    "开源元件依各自授权条款使用，著作权声明与授权条款仍归其作者所有。Apple、Google、Supabase、Dcard、Reddit、学校名称及其他第三方标志均属各权利人；本文提及不代表其背书。"
                )
            ]
        ),
        .init(
            title: .init("Thank you", "谢谢你"),
            paragraphs: [
                .init(
                    "Thank you to the open-source maintainers, testers, early users and everyone who has offered patient, specific feedback. You are helping Cheese become a more useful home for student life.",
                    "感谢所有开源维护者、测试者、早期用户，以及每一位耐心提供具体回馈的人。你们正让 Cheese 成为更有用的学生生活社群。"
                )
            ]
        )
    ]
}

struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        ZStack {
            AppColors.pageBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    documentHeader

                    ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                        sectionCard(section)
                    }

                    if !document.links.isEmpty {
                        referenceLinks
                    }

                    Link(destination: URL(string: "mailto:support@cheeseapp.dev")!) {
                        Label(L10n.tr("Contact support", "联络支援"), systemImage: "envelope.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AppColors.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .cheesePageTopBar(title: document.title)
        .tint(AppColors.textPrimary)
    }

    private var documentHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: document.icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(AppColors.link)
                    .frame(width: 44, height: 44)
                    .background(AppColors.link.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(document.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textMuted)
                }
            }

            Divider().overlay(AppColors.divider)

            Text(L10n.tr("Version 1.0 · Effective August 3, 2026", "版本 1.0 · 2026 年 8 月 3 日生效"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
        }
        .padding(18)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .cheeseCardChrome(cornerRadius: 18)
    }

    private func sectionCard(_ section: LegalSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title.value)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)

            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph.value)
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .fill(AppColors.link)
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                    Text(bullet.value)
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let footer = section.footer {
                Text(footer.value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.link)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.link.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .cheeseCardChrome(cornerRadius: 18)
    }

    private var referenceLinks: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.tr("References and projects", "参考与专案连结"))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)
                .padding(.bottom, 10)

            ForEach(Array(document.links.enumerated()), id: \.offset) { index, item in
                if let url = URL(string: item.destination) {
                    Link(destination: url) {
                        HStack(spacing: 10) {
                            Text(item.title.value)
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(AppColors.link)
                        .padding(.vertical, 12)
                    }
                }

                if index < document.links.count - 1 {
                    Divider().overlay(AppColors.divider)
                }
            }
        }
        .padding(18)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .cheeseCardChrome(cornerRadius: 18)
    }
}

struct LegalSection {
    let title: LocalizedLegalCopy
    var paragraphs: [LocalizedLegalCopy] = []
    var bullets: [LocalizedLegalCopy] = []
    var footer: LocalizedLegalCopy?
}

struct LocalizedLegalCopy {
    let english: String
    let chinese: String

    init(_ english: String, _ chinese: String) {
        self.english = english
        self.chinese = chinese
    }

    var value: String { L10n.tr(english, chinese) }
}

struct LegalReferenceLink {
    let title: LocalizedLegalCopy
    let destination: String
}
