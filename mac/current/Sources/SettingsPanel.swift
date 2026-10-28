import SwiftUI
import AppKit

extension Notification.Name { static let marginOpenSettings = Notification.Name("marginOpenSettings") }
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, personalization, appearance, trash
    var id: String { rawValue }
    var icon: String { switch self { case .general:"gearshape"; case .personalization:"person.text.rectangle"; case .appearance:"paintpalette"; case .trash:"trash" } }
}

struct SettingsPanel: View {
    @ObservedObject var store: ReaderStore
    @Binding var section: SettingsSection
    var close: () -> Void
    private var theme: ReaderTheme { ReaderTheme(settings.themeHex) }
    private var accent: Color { Color(hex:theme.accent) }
    private func L(_ zh:String,_ en:String)->String {store.localized(zh,en)}
    private var settings: ReaderSettings {store.library.settings}
    // Match the reader typography while preserving the relative text hierarchy.
    private func fontSize(_ size: CGFloat) -> CGFloat { size * CGFloat(settings.textSize / 13) }
    private var fontSample: LiteraryFontSample { ReaderFontSamples.sample(for: settings.language) }
    private func name(_ section:SettingsSection)->String {
        switch section {case .general:L("通用","General");case .personalization:L("个性化","Personalization");case .appearance:L("外观","Appearance");case .trash:L("最近删除","Recently deleted")}
    }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                BrandMark(foreground:NSColor(hex:theme.accent),background:NSColor(hex:theme.card)).frame(width:38,height:38)
                VStack(alignment:.leading,spacing:3) {Text(L("设置","Settings")).font(.system(size:fontSize(21),weight:.semibold));Text(Branding.displayName).font(.system(size:fontSize(11))).foregroundStyle(Color(hex:theme.muted))}
                Spacer()
                Button(L("完成","Done"),action:close).keyboardShortcut(.cancelAction).buttonStyle(.borderedProminent)
            }.padding(22).background(Color(hex:theme.sidebar))
            Divider()
            HStack(alignment:.top,spacing:0) {
                VStack(alignment:.leading,spacing:8) {
                    ForEach(SettingsSection.allCases) { item in
                        Button {section=item} label:{
                            HStack(spacing:10){Image(systemName:item.icon).frame(width:18);Text(name(item));Spacer(minLength:0)}
                                .font(.system(size:fontSize(12),weight:section == item ? .semibold:.regular))
                                .padding(11).frame(maxWidth:.infinity)
                                .contentShape(Rectangle())
                                .background(section == item ? accent.opacity(0.12):.clear,in:RoundedRectangle(cornerRadius:9))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    Text("\(Branding.displayName) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.system(size:fontSize(10))).foregroundStyle(Color(hex:theme.muted)).padding(10)
                }.padding(12).frame(width:190).background(Color(hex:theme.sidebar))
                Divider()
                ScrollView {
                    VStack(alignment:.leading,spacing:23) {
                        switch section {case .general:general;case .personalization:personalization;case .appearance:appearance;case .trash:trash}
                    }.padding(25).frame(maxWidth:.infinity,alignment:.leading)
                }.background(Color(hex:theme.center))
            }
        }.frame(width:760,height:620).foregroundStyle(Color(hex:theme.ink)).tint(accent)
        .font(.system(size:settings.textSize))
        .preferredColorScheme(theme.dark ? .dark : .light)
        .alert(L("需要留意","Please check"),isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error=nil}})) {Button(L("好","OK")){store.error=nil}} message:{Text(store.error ?? "")}
    }
    private func title(_ title:String,_ subtitle:String)->some View {
        VStack(alignment:.leading,spacing:6){Text(title).font(.system(size:fontSize(18),weight:.semibold));Text(subtitle).font(.system(size:fontSize(11))).foregroundStyle(Color(hex:theme.muted)).fixedSize(horizontal:false,vertical:true)}
    }
    private func card<Content:View>(@ViewBuilder _ content:()->Content)->some View {
        VStack(alignment:.leading,spacing:17,content:content).padding(17).frame(maxWidth:.infinity,alignment:.leading).background(Color(hex:theme.card),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(Color(hex:theme.border)))
    }
    private var general: some View {
        Group {
            title(L("让阅读顺手一点","Make yourself at home"),L("更改会自动保存，并立即应用。","Changes are saved automatically and applied immediately."))
            card {
                // Keep the native picker aligned to the trailing edge.
                HStack {
                    Text(L("界面语言","Interface language"))
                    Spacer()
                    Picker(L("界面语言","Interface language"),selection:Binding(get:{settings.language},set:{value in store.updateSettings{$0.language=value}})) {
                        ForEach(ReaderLanguage.allCases) { language in Text(store.t(language.label)).tag(language) }
                    }.labelsHidden().fixedSize()
                }
                Divider()
                HStack {Text(L("字体大小","Text size"));Spacer();Text("\(Int(settings.textSize)) pt").monospacedDigit().foregroundStyle(Color(hex:theme.muted))}
                Slider(value:Binding(get:{settings.textSize},set:{value in store.updateSettings{$0.textSize=value}}),in:11...20,step:1).accessibilityLabel(L("字体大小","Text size"))
                Text(L("调整界面、评论和讨论文字。PDF 正文请使用阅读区的缩放按钮。","Changes interface, note and conversation text. Use the reader's zoom controls for PDF text.")).font(.system(size:fontSize(11))).foregroundStyle(Color(hex:theme.muted))
                Text(fontSample.text).font(.system(size:settings.textSize)).fixedSize(horizontal:false,vertical:true)
                    .padding(12).frame(maxWidth:.infinity,alignment:.leading)
                    .background(Color(hex:theme.hover),in:RoundedRectangle(cornerRadius:8))
                    .help(fontSample.attribution)
            }
            card {
                Label(L("本地记录","Local records"),systemImage:"internaldrive").font(.system(size:fontSize(13),weight:.medium))
                Text(L("阅读记录和设置保存在本机，不改动原始 PDF。登录凭据保存在钥匙串，退出登录时清除。","Reading data and settings are saved locally without changing your PDFs. Sign-in details are stored in Keychain and cleared when you sign out.")).font(.system(size:fontSize(12))).foregroundStyle(Color(hex:theme.muted)).fixedSize(horizontal:false,vertical:true)
                Button(L("在 Finder 中查看","Show in Finder")){NSWorkspace.shared.open(store.dataDirectory)}
            }
        }
    }
    private var personalization: some View {
        Group {
            title(L("个性化指令","Custom instructions"),L("写下你希望 AI 遵循的回答方式。内容自动保存，并从下一次提问或追问起应用。","Describe how you want AI to respond. Changes are saved automatically and apply from your next question or follow-up."))
            card {
                Text(L("你的要求","Your preferences")).font(.system(size:fontSize(13),weight:.medium))
                TextEditor(text:Binding(get:{settings.customInstructions},set:{value in store.updateSettings{$0.customInstructions=value}}))
                    .font(.system(size:fontSize(13))).scrollContentBackground(.hidden)
                    .padding(8).frame(height:230)
                    .background(Color(hex:theme.hover),in:RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(Color(hex:theme.border)))
                    .accessibilityLabel(L("个性化指令","Custom instructions"))
                Text(L("这些指令会随每次提问发送给模型，独立于 ChatGPT 账户的个性化设置。留空即可停用。","These instructions are sent to the model with every question, independently of your ChatGPT account settings. Leave blank to turn them off."))
                    .font(.system(size:fontSize(11))).foregroundStyle(Color(hex:theme.muted)).fixedSize(horizontal:false,vertical:true)
                if settings.customInstructionsTooLong {
                    Text(L("个性化指令过长，请缩短至 16,000 个字符以内。","Custom instructions are too long. Shorten them to 16,000 characters or fewer."))
                        .font(.system(size:fontSize(11))).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)
                }
            }
        }
    }
    private var appearance: some View {
        Group {
            title(L("你的阅读氛围","Your reading atmosphere"),L("选择主题色或背景图片，再分别调整阅读区与侧栏的遮罩。","Choose a color or image, then adjust the reader and sidebar surfaces separately."))
            card {
                Text(L("背景主题色","Background color")).font(.system(size:fontSize(13),weight:.medium))
                HStack(spacing:10) {
                    ForEach(ReaderTheme.presets,id:\.hex) { value in preset(value.hex,store.t(value.label)) }
                    Spacer()
                    ColorPicker(L("自定义","Custom"),selection:Binding(get:{Color(hex:settings.themeHex)},set:{value in store.chooseTheme(NSColor(value).hex)}),supportsOpacity:false).fixedSize()
                }
                Divider()
                HStack {
                    VStack(alignment:.leading,spacing:4) {Text(L("背景图片","Background image")).font(.system(size:fontSize(13),weight:.medium));Text(settings.backgroundImage == nil ? L("尚未选择图片","No image selected"):L("图片副本已保存在本机","A local copy is saved")).font(.system(size:fontSize(11))).foregroundStyle(Color(hex:theme.muted))}
                    Spacer()
                    Button(L("选择图片…","Choose image…"),action:store.chooseBackgroundImage)
                    if settings.backgroundImage != nil {Button(L("移除","Remove"),action:store.removeBackgroundImage)}
                }
                if let image=store.backgroundImage {Image(nsImage:image).resizable().scaledToFill().frame(height:90).frame(maxWidth:.infinity).clipped().clipShape(RoundedRectangle(cornerRadius:9))}
                Text(L("支持 PNG、JPEG、HEIC、TIFF。只在本机使用，不随问题发送。","PNG, JPEG, HEIC and TIFF. Used locally; never sent with questions.")).font(.system(size:fontSize(10))).foregroundStyle(Color(hex:theme.muted))
            }
            card {
                opacitySlider(L("中心区域不透明度","Center opacity"),value:settings.centerOpacity) {newValue in store.updateSettings{$0.centerOpacity=newValue}}
                opacitySlider(L("两侧区域不透明度","Sidebars opacity"),value:settings.sidesOpacity) {newValue in store.updateSettings{$0.sidesOpacity=newValue}}
                Text(L("向左拖动会露出更多背景。PDF 纸页保持不透明，确保正文清楚。","Move left to reveal more of the background. PDF pages remain opaque for clear reading.")).font(.system(size:fontSize(11))).foregroundStyle(Color(hex:theme.muted))
                themePreview
            }
            card {
                Text(L("讨论气泡","Conversation bubbles")).font(.system(size:fontSize(13),weight:.medium))
                ColorPicker(L("你的发言","Your messages"),selection:Binding(get:{Color(hex:store.library.userBubble)},set:{store.library.userBubble=NSColor($0).hex;store.save()}),supportsOpacity:false)
                ColorPicker(L("AI 的回复","AI replies"),selection:Binding(get:{Color(hex:store.library.aiBubble)},set:{store.library.aiBubble=NSColor($0).hex;store.save()}),supportsOpacity:false)
            }
        }
    }
    private func preset(_ hex:String,_ name:String)->some View {
        Button {store.chooseTheme(hex)} label:{Circle().fill(Color(hex:hex)).frame(width:27,height:27).overlay(Circle().stroke(settings.themeHex == hex ? accent:Color(hex:theme.border),lineWidth:settings.themeHex == hex ? 2:0.5)).contentShape(Rectangle())}.buttonStyle(.plain).help(name).accessibilityLabel(name)
    }
    private func opacitySlider(_ label:String,value:Double,set:@escaping(Double)->Void)->some View {
        VStack(spacing:6) {HStack {Text(label);Spacer();Text("\(Int(value*100))%").monospacedDigit().foregroundStyle(Color(hex:theme.muted))}.font(.system(size:fontSize(12)));Slider(value:Binding(get:{value},set:set),in:0...1,step:0.05).accessibilityLabel(label)}
    }
    private var themePreview:some View {
        ZStack {
            Color(hex:settings.themeHex)
            if let image=store.backgroundImage {Image(nsImage:image).resizable().scaledToFill().frame(height:100).clipped()}
            HStack(spacing:2) {
                Rectangle().fill(Color(hex:theme.sidebar).opacity(settings.sidesOpacity)).frame(width:70).overlay(Image(systemName:"folder").foregroundStyle(accent))
                Rectangle().fill(Color(hex:theme.center).opacity(settings.centerOpacity)).overlay(RoundedRectangle(cornerRadius:2).fill(.white).padding(.horizontal,42).padding(.vertical,12).overlay(Image(systemName:"doc.text").foregroundStyle(Color(hex:"283C36"))))
                Rectangle().fill(Color(hex:theme.sidebar).opacity(settings.sidesOpacity)).frame(width:100).overlay(Image(systemName:"text.bubble").foregroundStyle(accent))
            }
        }.frame(height:100).clipShape(RoundedRectangle(cornerRadius:9)).accessibilityLabel(L("背景效果预览","Background preview"))
    }
    private var trash: some View {
        Group {
            title(L("最近删除","Recently deleted"),L("删除只会将记录移到这里。恢复后，原文位置、评论和完整对话都会回来。","Deleted items move here. Restore an item to recover its source position, note and full conversation."))
            card {
                Label(L("保留至你恢复","Kept until you restore"),systemImage:"arrow.uturn.backward.circle").font(.system(size:fontSize(13),weight:.medium))
                Text(L("本版不会自动永久删除，也不设恢复截止日。关闭应用后，最近删除的记录仍会保留。","This version never permanently deletes items automatically and has no restore deadline. Deleted items are kept after the app closes.")).font(.system(size:fontSize(12))).foregroundStyle(Color(hex:theme.muted))
            }
            if store.trashedAnnotations.isEmpty {
                VStack(spacing:12) {Image(systemName:"trash").font(.system(size:32,weight:.light));Text(L("这里暂时是空的","Nothing here yet"));Text(L("高亮、评论和讨论删除后，会出现在这里。","Deleted highlights, notes and conversations appear here.")).font(.system(size:fontSize(11))).foregroundStyle(Color(hex:theme.muted))}.frame(maxWidth:.infinity).padding(.vertical,45)
            } else {
                ForEach(store.trashedAnnotations) {item in
                    card {
                        HStack {Label(store.t(item.annotation.kind.label),systemImage:item.annotation.kind.icon).font(.system(size:fontSize(11),weight:.semibold)).foregroundStyle(accent);Spacer();Button(L("恢复","Restore")){_ = store.restoreAnnotation(item.id,documentID:item.documentID)}.buttonStyle(.bordered)}
                        Text(item.annotation.quote).font(.system(size:fontSize(12))).lineLimit(3)
                        if !item.annotation.comment.isEmpty {Text(item.annotation.comment).font(.system(size:fontSize(11))).foregroundStyle(Color(hex:theme.muted)).lineLimit(2)}
                        HStack {Text(item.documentTitle).lineLimit(1);Spacer();Text(L("第 \(item.annotation.page+1) 页","Page \(item.annotation.page+1)"))}.font(.system(size:fontSize(10))).foregroundStyle(Color(hex:theme.muted))
                        if let date=item.annotation.deletedAt {Text(L("删除于 ","Deleted ")+date.formatted(Date.FormatStyle(date:.abbreviated,time:.shortened).locale(Locale(identifier:settings.language.localeIdentifier)))).font(.system(size:fontSize(10))).foregroundStyle(Color(hex:theme.muted))}
                        if item.annotation.kind == .question {Text(L("\(item.annotation.messages.count) 条发言","\(item.annotation.messages.count) messages")).font(.system(size:fontSize(10))).foregroundStyle(Color(hex:theme.muted))}
                    }
                }
            }
        }
    }
}
