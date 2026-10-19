import SwiftUI
import AppKit
import ZawiyaCore
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var workspace: Workspace
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Namespace private var navigationHighlight
    @State private var targeted = false
    @ObservedObject private var announcements = Services.announcements
    var dark: Bool { scheme == .dark }
    var motion: Bool { preferences.animationsEnabled && !reduceMotion }
    func t(_ ar: String, _ en: String) -> String { preferences.text(ar, en) }
    var body: some View {
        GeometryReader { geometry in
          HStack(spacing: 0) {
            sidebar(compact: geometry.size.width < 940).frame(width: geometry.size.width < 940 ? 76 : 196)
            Rectangle().fill(Brand.line(dark)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().overlay(Brand.line(dark))
                ScrollViewReader { proxy in ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if workspace.section == "recipes" { recipes }
                        else if workspace.section == "capabilities" { capabilities }
                        else if workspace.section == "settings" { settings }
                        else { workspaceView }
                    }.frame(maxWidth: .infinity, alignment: .leading).id(workspace.section).transition(BrandMotion.transition(motion)).padding(geometry.size.width < 940 ? 20 : 28)
                }.onChange(of: workspace.section) { _, section in withAnimation(nil) { proxy.scrollTo(section, anchor: .top) } } }
                footer
            }
          }
        }
        .background(Brand.background(dark))
        .foregroundStyle(Color(hex: dark ? 0xF2F3F5 : 0x0B0D10))
        .font(.system(size: 14))
        .toggleStyle(.switch)
        .environment(\.layoutDirection, preferences.arabic ? .rightToLeft : .leftToRight)
        .environment(\.locale, Locale(identifier: preferences.arabic ? "ar-SA" : "en-US"))
        .environment(\.zawiyaMotion, preferences.animationsEnabled)
        .frame(minWidth: 760, minHeight: 620)
        .animation(BrandMotion.animation(motion), value: workspace.section)
        .sheet(isPresented: $workspace.showToolBrowser) { ToolBrowser().environmentObject(preferences).environmentObject(workspace).preferredColorScheme(preferences.scheme) }
        .alert(t("تعذر إكمال الإجراء", "Action could not finish"), isPresented: Binding(get: { workspace.message != nil }, set: { if !$0 { workspace.message = nil } })) {
            Button(t("حسنًا", "OK")) { workspace.message = nil }
        } message: { Text(workspace.message ?? "") }
        .onChange(of: workspace.tool) { _, _ in workspace.normalizeFormat() }
        .onAppear {
            let open = openWindow
            workspace.presentMain = { open(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            if let index = CommandLine.arguments.firstIndex(of: "--demo-directory"), CommandLine.arguments.count > index + 1, workspace.items.isEmpty {
                let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                workspace.add(files.filter { ["png", "jpg", "pdf", "wav", "mp4", "srt"].contains($0.pathExtension) }.sorted { $0.lastPathComponent < $1.lastPathComponent })
            }
        }
    }

    func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                ZawiyaMark(color: Brand.accent(dark)).frame(width: 38, height: 38)
                if !compact { VStack(alignment: .leading, spacing: 2) {
                    Text("Zawiya Tools").font(.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8).environment(\.layoutDirection, .leftToRight)
                    Text("أداة زاوية").font(.system(size: 11)).foregroundStyle(Brand.muted(dark))
                } }
            }.padding(.top, 26)
            VStack(spacing: 6) {
                navigation("workspace", t("مساحة العمل", "Workspace"), "square.grid.2x2", compact: compact)
                navigation("recipes", t("إعدادات جاهزة", "Presets"), "slider.horizontal.3", compact: compact)
                navigation("capabilities", t("القدرات والمحركات", "Capabilities"), "square.stack.3d.up", compact: compact)
                navigation("settings", t("الإعدادات", "Settings"), "gearshape", compact: compact)
            }
            Spacer()
            if compact { Image(systemName: "lock.shield").foregroundStyle(Brand.accent(dark)).frame(maxWidth: .infinity).padding(.bottom, 10).help(t("محلي بالكامل", "Entirely local")) }
            else { VStack(alignment: .leading, spacing: 8) {
                AnnouncementCard(store: announcements, arabic: preferences.arabic, dark: dark).padding(.bottom, 4)
                Label(t("معالجة محلية", "Processed on your Mac"), systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(Brand.muted(dark))
                Button { workspace.section = "settings" } label: {
                    Text("\(AppInfo.author(preferences.arabic)) · v\(AppInfo.version)").font(.system(size: 10)).foregroundStyle(Brand.muted(dark).opacity(0.75))
                }.buttonStyle(.plain).help(t("حول التطبيق", "About"))
            }.padding(.horizontal, 10)

            }
        }.padding(.horizontal, compact ? 10 : 18).padding(.bottom, 20).background(Brand.surface(dark))
    }
    func navigation(_ id: String, _ title: String, _ symbol: String, compact: Bool) -> some View {
        Button { workspace.section = id } label: {
            HStack(spacing: 12) { Image(systemName: symbol).frame(width: 20); if !compact { Text(title).lineLimit(1).minimumScaleFactor(0.8); Spacer(); if id == "workspace", workspace.isRunning { ProgressView().controlSize(.mini) } } }
                .font(.system(size: 13, weight: workspace.section == id ? .semibold : .regular))
                .padding(.horizontal, 13).padding(.vertical, 11).contentShape(Rectangle())
                .foregroundStyle(workspace.section == id ? Brand.accent(dark) : Brand.muted(dark))
                .background { if workspace.section == id { RoundedRectangle(cornerRadius: 11).fill(Brand.accent(dark).opacity(0.10)).matchedGeometryEffect(id: "sidebar-selection", in: navigationHighlight) } }
        }.buttonStyle(.plain).accessibilityLabel(title).help(title).accessibilityIdentifier("nav-\(id)")
    }
    var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.section == "settings" ? t("الإعدادات", "Settings") : workspace.section == "recipes" ? t("إعدادات جاهزة", "Presets") : workspace.section == "capabilities" ? t("الصيغ والمحركات", "Formats & engines") : t("مساحة العمل", "Workspace")).font(.system(size: 18, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(t("أداة زاوية · أحمد مروان", "File utilities · Ahmed Marwan")).font(.system(size: 11)).foregroundStyle(Brand.muted(dark))
            }
            Spacer()
            Button { workspace.showToolBrowser = true } label: { HStack(spacing: 8) { Image(systemName: "magnifyingglass"); Text(t("الأدوات", "Tools")); Text("⌘K").font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.muted(dark)) }.font(.system(size: 12)).padding(10).background(Brand.raised(dark), in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain).accessibilityLabel(t("البحث في كل الأدوات", "Search all tools"))
            Button { preferences.arabic.toggle() } label: { Text(preferences.arabic ? "EN" : "عربي").font(.system(size: 12, weight: .semibold)).frame(width: 36, height: 36) }.buttonStyle(.plain).accessibilityLabel(t("التبديل إلى الإنجليزية", "Switch to Arabic"))
            Button { preferences.appearance = dark ? "light" : "dark" } label: { Image(systemName: dark ? "sun.max" : "moon").frame(width: 36, height: 36).background(Brand.raised(dark), in: Circle()) }.buttonStyle(.plain).accessibilityLabel(t("تبديل المظهر", "Toggle appearance"))
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
    var workspaceView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !workspace.items.isEmpty {
                HStack(spacing: 14) {
                    Label(t("الملفات: \(workspace.items.count)", "Files: \(workspace.items.count)"), systemImage: "square.stack")
                    Text(ByteCountFormatter.string(fromByteCount: workspace.items.reduce(0) { $0 + $1.inputBytes }, countStyle: .file)).monospacedDigit()
                    Spacer()
                    if workspace.completed > 0 { Label(t("\(workspace.completed) مكتمل", "\(workspace.completed) completed"), systemImage: "checkmark.circle").foregroundStyle(Brand.accent(dark)) }
                }.font(.system(size: 11)).foregroundStyle(Brand.muted(dark)).padding(.horizontal, 2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) { dropZone; if !workspace.items.isEmpty { queue } }.frame(minWidth: 350, maxWidth: .infinity)
                    controls.frame(width: 292)
                }
                VStack(spacing: 18) { dropZone; controls; if !workspace.items.isEmpty { queue } }
            }
            if workspace.items.isEmpty {
                HStack(spacing: 20) {
                    shortcutHint("⇧", t("تحويل", "Convert")); shortcutHint("⌘", t("أدوات", "Tools")); shortcutHint("⌃", t("إجراءات", "Actions"))
                    Spacer()
                    Text(t("أثناء السحب من Finder", "While dragging from Finder")).font(.system(size: 10)).foregroundStyle(Brand.muted(dark))
                }.padding(.horizontal, 4)
            }
        }
    }
    func shortcutHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.system(size: 12, weight: .medium)).frame(width: 25, height: 23).background(Brand.raised(dark), in: RoundedRectangle(cornerRadius: 5))
            Text(label).font(.system(size: 11)).foregroundStyle(Brand.muted(dark))
        }
    }
    var dropZone: some View {
        Group {
            if workspace.items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(Brand.accent(dark)).padding(.bottom, 4)
                    Text(t("أفلت ملفاتك هنا", "Drop your files here")).font(.system(size: 21, weight: .semibold))
                    Text(t("صور، فيديو، صوت، PDF وترجمة", "Images, video, audio, PDF and subtitles")).font(.system(size: 12)).foregroundStyle(Brand.muted(dark))
                    Button { workspace.chooseFiles() } label: { Label(t("اختيار ملفات", "Choose files"), systemImage: "plus") }.buttonStyle(PrimaryButton()).disabled(workspace.isRunning).padding(.top, 8)
                    Text(t("أو ابدأ بسحب ملف من Finder واضغط ⇧", "Or drag a file from Finder and tap ⇧")).font(.system(size: 11)).foregroundStyle(Brand.muted(dark)).padding(.top, 8)
                }.frame(maxWidth: .infinity, minHeight: 290).padding(20)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle").foregroundStyle(Brand.accent(dark))
                    Text(t("أفلت ملفات إضافية", "Drop more files")).font(.system(size: 12))
                    Spacer()
                    Button(t("اختيار…", "Browse…")) { workspace.chooseFiles() }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Brand.accent(dark)).disabled(workspace.isRunning)
                }.padding(16)
            }
        }.background(Brand.accent(dark).opacity(targeted ? 0.08 : 0.015), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Brand.accent(dark) : Brand.line(dark), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { workspace.load($0) }
            .animation(.easeOut(duration: motion ? 0.12 : 0), value: targeted)
    }
    var queue: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(t("الملفات", "Files")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !workspace.pending.isEmpty {
                        Button { workspace.showQuickWheel() } label: { Label(t("العجلة", "Wheel"), systemImage: "circle.dotted.circle") }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Brand.accent(dark)).disabled(workspace.isRunning).help("⌘⇧K")
                    }
                    if workspace.completed > 0 && workspace.pending.isEmpty { Button(t("تكرار الدفعة", "Repeat batch")) { workspace.requeueAll() }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Brand.accent(dark)).disabled(workspace.isRunning) }
                    if !workspace.items.isEmpty { Button(t("إفراغ", "Clear")) { workspace.clear() }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(Brand.muted(dark)).disabled(workspace.isRunning) }
                }
                if !workspace.allOutputs.isEmpty && !workspace.isRunning {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent(dark))
                        Text(workspace.pending.isEmpty ? t("ملفاتك جاهزة", "Your files are ready") : t("نتائج سابقة متاحة", "Previous results available")).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button(t("عرض النتائج", "Show results")) { workspace.reveal(workspace.allOutputs) }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Brand.accent(dark))
                    }.padding(12).background(Brand.accent(dark).opacity(0.07), in: RoundedRectangle(cornerRadius: 10)).transition(BrandMotion.transition(motion))
                }
                if workspace.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(Brand.muted(dark).opacity(0.55))
                        Text(t("مساحة لملفك القادم", "Room for your next file")).font(.system(size: 13)).foregroundStyle(Brand.muted(dark))
                        Text(t("الأصول تبقى محفوظة. النتائج في مجلد مستقل.", "Originals stay safe. Results go into a separate folder.")).font(.system(size: 11)).foregroundStyle(Brand.muted(dark))
                    }.frame(maxWidth: .infinity).padding(.vertical, 44)
                } else {
                    LazyVStack(spacing: 12) { ForEach(workspace.items) { item in
                        QueueRow(item: item).environmentObject(workspace).environmentObject(preferences)
                        if item.id != workspace.items.last?.id { Divider().overlay(Brand.line(dark)) }
                    } }.animation(BrandMotion.animation(motion), value: workspace.items.map(\.id))
                }
            }
        }
    }
    var controls: some View {
        Panel {
            VStack(alignment: .leading, spacing: 17) {
                Text(t("إعداد العملية", "Job settings")).font(.system(size: 13, weight: .semibold))
                SelectionMenu(label: t("الأداة", "Tool"), value: workspace.tool.title(preferences.arabic), symbol: workspace.tool.icon) {
                    ForEach(Tool.allCases) { tool in
                        Button { workspace.selectTool(tool) } label: {
                            if workspace.tool == tool { Label(tool.title(preferences.arabic), systemImage: "checkmark") }
                            else { Text(tool.title(preferences.arabic)) }
                        }.disabled(!workspace.compatibleTools.contains(tool))
                    }
                    Divider()
                    Button(t("بحث في كل الأدوات…", "Search all tools…")) { workspace.showToolBrowser = true }
                }.disabled(workspace.isRunning).accessibilityIdentifier("menu-tools")
                if !workspace.pending.isEmpty && !workspace.compatibleTools.contains(workspace.tool) {
                    Text(t("الأداة المحددة لا تناسب هذه الدفعة. اختر أداة متاحة أو افصل أنواع الملفات.", "This tool cannot process this batch. Choose an available tool or split the file types.")).font(.system(size: 11)).foregroundStyle(.orange)
                }
                if workspace.tool == .convert || workspace.tool == .compress {
                    if workspace.tool == .convert || workspace.pending.allSatisfy({ $0.kind == .image }) {
                        SelectionMenu(label: t("الصيغة", "Format"), value: workspace.formats.isEmpty ? t("لا توجد صيغة مشتركة", "No shared format") : workspace.options.format.uppercased(), symbol: "doc.badge.arrow.up") {
                            ForEach(MenuCatalog.ordered(workspace.formats, favorites: preferences.favoriteFormats), id: \.self) { format in
                                Button { workspace.selectFormat(format) } label: {
                                    if workspace.options.format == format { Label(format.uppercased(), systemImage: "checkmark") }
                                    else { Text(format.uppercased()) }
                                }
                            }
                        }.disabled(workspace.isRunning || workspace.formats.isEmpty).accessibilityIdentifier("menu-formats")
                        if !workspace.formats.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: preferences.favoriteFormats.contains(workspace.options.format) ? "star.fill" : "star").foregroundStyle(Brand.accent(dark))
                                Button(preferences.favoriteFormats.contains(workspace.options.format) ? t("إزالة من المفضلة", "Unpin format") : t("تثبيت هذه الصيغة", "Pin this format")) { preferences.toggleFavorite(workspace.options.format) }.buttonStyle(.plain).font(.system(size: 11))
                                Spacer()
                            }.help(t("الصيغ المفضلة تظهر أولًا في عجلة السحب", "Pinned formats appear first in the drag wheel"))
                        }
                        if workspace.formats.isEmpty { Text(t("هذه الأنواع لا تشترك بصيغة واحدة. افصل الدفعات حسب النوع.", "These file types have no shared format. Use separate batches.")).font(.system(size: 11)).foregroundStyle(.orange) }
                    }
                }
                if workspace.tool == .compress || workspace.tool == .resize || (workspace.tool == .convert && workspace.pending.contains(where: { [.image, .video, .audio].contains($0.kind) })) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(t("جودة الصيغ المضغوطة", "Lossy quality")); Spacer(); Text("\(workspace.options.quality)%").monospacedDigit().foregroundStyle(Brand.accent(dark)) }
                        Slider(value: Binding(get: { Double(workspace.options.quality) }, set: { workspace.options.quality = Int($0) }), in: 10...100, step: 1).tint(Brand.accent(dark))
                        Text(t("لا تغيّر جودة صيغ Lossless وGIF وWMA.", "Lossless formats, GIF and WMA keep their quality.")).font(.system(size: 10)).foregroundStyle(Brand.muted(dark)).fixedSize(horizontal: false, vertical: true)
                    }.font(.system(size: 12))
                }
                if workspace.tool == .resize || (workspace.tool == .convert && workspace.pending.contains(where: { $0.kind == .pdf })) {
                    SelectionMenu(label: t("الضلع الأطول · px", "Longest edge · px"), value: "\(workspace.options.maxDimension) px", symbol: "arrow.up.left.and.arrow.down.right") { ForEach([800, 1200, 1600, 1920, 2560, 3840], id: \.self) { size in Button("\(size) px") { workspace.options.maxDimension = size } } }.disabled(workspace.isRunning).accessibilityIdentifier("menu-size")
                    Text(t("المقاس يطبق على تغيير مقاس الصور وتصدير صفحات PDF فقط.", "Size applies to image resizing and PDF page exports only.")).font(.system(size: 10)).foregroundStyle(Brand.muted(dark))
                }
                if [.trim, .videoFrame].contains(workspace.tool) {
                    TextField(t("البداية بالثواني", "Start in seconds"), value: $workspace.options.start, format: .number)
                    if workspace.tool == .trim { TextField(t("المدة بالثواني", "Duration in seconds"), value: $workspace.options.duration, format: .number) }
                }
                if workspace.tool == .extractText { Text(t("التعرف محلي. العربية تعتمد على لغات Vision المتاحة؛ راجع صفحة القدرات.", "OCR is local. Arabic depends on installed Vision language support; see Capabilities.")).font(.system(size: 11)).foregroundStyle(Brand.muted(dark)) }
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text(t("حفظ النتائج", "SAVE RESULTS")).font(.system(size: 10, weight: .medium)).foregroundStyle(Brand.muted(dark))
                    Text(workspace.activeOutput?.path ?? t("Zawiya Exports بجوار أول ملف", "Zawiya Exports beside the first file")).font(.system(size: 11)).lineLimit(2).textSelection(.enabled).environment(\.layoutDirection, .leftToRight)
                    Button(t("تغيير المجلد…", "Change folder…")) { workspace.chooseOutput() }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Brand.accent(dark))
                }
                Text(t("يتم إنشاء نسخ جديدة دائمًا. قد يختلف حجم الضغط حسب المحتوى.", "Always creates new copies. Compression savings depend on the content.")).font(.system(size: 10)).foregroundStyle(Brand.muted(dark)).lineSpacing(3)
            }
        }.disabled(workspace.isRunning).animation(BrandMotion.animation(motion), value: workspace.tool)
    }
    var recipes: some View {
        VStack(alignment: .leading, spacing: 20) {
            title(t("إعدادات تختصر التكرار", "Less repetition. Saved settings."), t("تطبق القيم ثم تعرضها للمراجعة قبل التنفيذ.", "Apply a preset, review the settings, then run."))
            preset("product", "photo", t("صور المنتجات", "Product images"), t("الضلع الأطول 1600px مع الحفاظ على النسبة، دون تكبير الصور الصغيرة.", "1600px longest edge. Preserve proportions, never upscale."))
            preset("web", "globe", t("صور للويب", "Web images"), t("WebP بجودة 78%، مع الحفاظ على الشفافية.", "WebP at 78% quality, preserving transparency."))
            preset("social", "film", t("فيديو خفيف", "Lighter video"), t("MP4 بترميز H.264 وجودة 76%.", "MP4 with H.264 at 76% quality."))
            preset("clean", "eye.slash", t("نسخة نظيفة", "Clean copy"), t("حذف Metadata من الصور أو مسارات الصوت والفيديو المدعومة.", "Remove metadata from images or supported media streams."))
            Text(t("هذه إعدادات لعملية واحدة. محرر الوصفات المتسلسلة ضمن المرحلة التالية.", "These presets configure one operation. Multi-step recipes are planned for a later stage.")).font(.system(size: 12)).foregroundStyle(Brand.muted(dark))
        }
    }
    func preset(_ id: String, _ icon: String, _ name: String, _ detail: String) -> some View {
        Panel { HStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 25)).foregroundStyle(Brand.accent(dark)).frame(width: 44)
            VStack(alignment: .leading, spacing: 7) { Text(name).font(.system(size: 16, weight: .semibold)); Text(detail).font(.system(size: 12)).foregroundStyle(Brand.muted(dark)) }
            Spacer(); Button(t("استخدام", "Use preset")) { workspace.applyRecipe(id) }.buttonStyle(PrimaryButton()).disabled(workspace.isRunning)
        } }
    }
    var capabilities: some View {
        VStack(alignment: .leading, spacing: 18) {
            title(t("الصيغ المتاحة", "Available formats"), t("التوافق الفعلي مع المحركات المثبتة على هذا الماك.", "Available output formats depend on the engines installed on this Mac."))
            ForEach([FileKind.image, .video, .audio, .pdf, .subtitle], id: \.self) { kind in
                Panel { HStack(alignment: .top, spacing: 16) {
                    Image(systemName: kind.symbol).font(.system(size: 22)).foregroundStyle(Brand.accent(dark)).frame(width: 30)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(kind.rawValue.uppercased()).font(.system(size: 12, weight: .bold, design: .monospaced))
                        Text(Engines.formats(for: kind).map { $0.uppercased() }.joined(separator: "  ·  ")).font(.system(size: 12)).foregroundStyle(Brand.muted(dark)).textSelection(.enabled)
                    }; Spacer()
                } }
            }
            Panel { VStack(alignment: .leading, spacing: 12) {
                Text(t("المحركات على هذا الجهاز", "Engines on this Mac")).font(.headline)
                ForEach(["ffmpeg", "cwebp", "zip"], id: \.self) { name in HStack { Text(name).monospaced(); Spacer(); Text(Engines.executable(name) != nil ? t("متاح", "Available") : t("غير موجود", "Missing")).foregroundStyle(Engines.executable(name) != nil ? Brand.accent(dark) : .orange) } }
                Text("OCR: " + (workspace.ocrLanguages?.joined(separator: ", ") ?? t("جارٍ قراءة اللغات…", "Loading languages…"))).font(.system(size: 11)).foregroundStyle(Brand.muted(dark)).textSelection(.enabled)
            } }.task { await workspace.loadOCRLanguages() }
            Panel { VStack(alignment: .leading, spacing: 9) {
                Text(t("لم تُنفذ بعد", "Not implemented yet")).font(.headline)
                Text(t("Office وPages وEPUB · إعادة بناء PDF إلى Word · فك الأرشيف · تحرير الصور والتعليقات والحجب · دمج وتقطيع الفيديو المتقدم · AVIF export · وصفات متسلسلة ومجلدات مراقبة.", "Office, Pages and EPUB · PDF to editable Word · archive extraction · image editing, annotation and redaction · advanced media editing · AVIF export · multi-step recipes and watched folders.")).font(.system(size: 12)).foregroundStyle(Brand.muted(dark)).lineSpacing(5)
            } }
        }
    }
    var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            title(t("التفضيلات", "Preferences"), t("اضبط المظهر والعجلة والاستجابة على طريقتك.", "Tune the appearance, wheel and feedback to your workflow."))
            Panel { CreditsView(arabic: preferences.arabic, dark: dark) }
            Panel { VStack(alignment: .leading, spacing: 20) {
                Picker(t("المظهر", "Appearance"), selection: $preferences.appearance) { Text(t("داكن", "Dark")).tag("dark"); Text(t("فاتح", "Light")).tag("light"); Text(t("حسب النظام", "System")).tag("system") }.pickerStyle(.segmented)
                Toggle(t("الواجهة العربية", "Arabic interface"), isOn: $preferences.arabic).tint(Brand.accent(dark))
                Toggle(t("حركات خفيفة للواجهة", "Subtle interface animations"), isOn: $preferences.animationsEnabled).tint(Brand.accent(dark))
                Text(t("يتوقف التحريك تلقائيًا عند تفعيل Reduce Motion في macOS.", "Animations also respect the macOS Reduce Motion setting.")).font(.system(size: 11)).foregroundStyle(Brand.muted(dark))
            } }
            Panel { VStack(alignment: .leading, spacing: 16) {
                Text(t("الصوت والاستجابة", "Sound & feedback")).font(.system(size: 13, weight: .semibold))
                Toggle(t("صوت التك عند تغيير الاختيار", "Tick when the selection changes"), isOn: $preferences.soundsEnabled).tint(Brand.accent(dark))
                HStack(spacing: 14) {
                    Image(systemName: "speaker.wave.1").foregroundStyle(Brand.muted(dark))
                    Slider(value: $preferences.soundVolume, in: 0...1, step: 0.05).tint(Brand.accent(dark)).accessibilityLabel(t("مستوى صوت العجلة", "Wheel sound volume"))
                    Text("\(Int(preferences.soundVolume * 100))%").font(.system(size: 11)).monospacedDigit().frame(width: 40)
                    Button(t("تجربة الصوت", "Preview sound")) {
                        if !InteractionFeedback.shared.play(.tick, preferences: preferences) { workspace.message = t("تعذر تشغيل الصوت. تحقق من جهاز إخراج الصوت في macOS.", "Audio could not start. Check the macOS output device.") }
                    }.buttonStyle(.bordered).controlSize(.small)
                }.disabled(!preferences.soundsEnabled)
                Toggle(t("استجابة اهتزازية خفيفة", "Subtle haptic feedback"), isOn: $preferences.hapticsEnabled).tint(Brand.accent(dark))
                Text(t("صوت قصير لكل انتقال بين الخيارات، دون تكرار عند ثبات المؤشر. الاهتزاز حسب دعم الجهاز.", "One short tick per selection change, never a loop. Haptics depend on hardware support.")).font(.system(size: 11)).foregroundStyle(Brand.muted(dark))
            } }
            Panel { VStack(alignment: .leading, spacing: 16) {
                Text(t("عجلة الملفات", "File wheel")).font(.system(size: 13, weight: .semibold))
                Toggle(t("عجلة السحب في Finder", "Finder drag wheel"), isOn: $preferences.wheelEnabled).tint(Brand.accent(dark))
                Picker(t("سطح العجلة", "Wheel surface"), selection: $preferences.wheelAppearance) { Text(t("زجاجي", "Glass")).tag("glass"); Text(t("مصمت", "Solid")).tag("solid") }.pickerStyle(.segmented).frame(maxWidth: 340)
                Text(t("التنظيف وPDF وOCR وZIP تنفذ مباشرةً في الخلفية. الأدوات التي تنتهي بـ … تفتح الإعدادات. النتائج نسخ جديدة في Zawiya Exports أو المجلد الذي اخترته.", "Clean metadata, PDF tools, OCR and ZIP run immediately in the background. Tools ending in … open settings. Results are new copies in Zawiya Exports or your chosen folder.")).font(.system(size: 11)).foregroundStyle(Brand.muted(dark)).fixedSize(horizontal: false, vertical: true)
                Text(t("⇧ تحويل   ⌘ أدوات   ⌃ إجراءات\nاضغط المفتاح أثناء السحب. في العجلة اليدوية: الأسهم للتنقل، Enter للتنفيذ، وEsc للإغلاق.", "⇧ Convert   ⌘ Tools   ⌃ Actions\nTap a modifier while dragging. In the manual wheel: arrows to choose, Enter to apply, Esc to close.")).font(.system(size: 12)).foregroundStyle(Brand.muted(dark)).lineSpacing(6)
            } }
            Panel { VStack(alignment: .leading, spacing: 12) {
                Text(t("الصيغ المثبتة", "Pinned formats")).font(.headline)
                Text(t("تظهر أولًا في القوائم وعجلة السحب، دون إخفاء باقي الصيغ.", "Shown first in menus and the drag wheel, without hiding other formats.")).font(.system(size: 12)).foregroundStyle(Brand.muted(dark))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                    ForEach(preferences.favoriteFormats, id: \.self) { format in Button { preferences.toggleFavorite(format) } label: { HStack { Image(systemName: "star.fill"); Text(format.uppercased()); Image(systemName: "xmark").font(.system(size: 9)) }.font(.system(size: 11)).padding(10).background(Brand.raised(dark), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).help(t("إزالة من المفضلة", "Unpin format")) }
                }
                if preferences.favoriteFormats.isEmpty { Text(t("ثبّت صيغة من إعدادات العملية.", "Pin a format from job settings.")).font(.system(size: 12)).foregroundStyle(Brand.muted(dark)) }
            } }
            UpdatesPanel(updater: Services.updater, arabic: preferences.arabic, dark: dark)
            Panel { VStack(alignment: .leading, spacing: 10) {
                Text("com.ahmedqa.zawiyatools").font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                Text(t("معالجة الملفات محلية بالكامل، ولا تُرفع ملفاتك أو أسماؤها لأي خادم.\nالاتصال الوحيد: التحقق من التحديثات وجلب بطاقة الإعلان من GitHub، دون إرسال أي بيانات عنك.\nFFmpeg وcwebp مضمّنان داخل التطبيق.", "Files are processed entirely on this Mac; files and names are never uploaded.\nThe only connections: update checks and the announcement card from GitHub, sending no data about you.\nFFmpeg and cwebp ship inside the app.")).font(.system(size: 12)).foregroundStyle(Brand.muted(dark)).lineSpacing(6)
            } }
        }.frame(maxWidth: 680, alignment: .leading)
    }
    func title(_ headline: String, _ subtitle: String) -> some View { VStack(alignment: .leading, spacing: 8) { Text(headline).font(.system(size: 23, weight: .semibold)); Text(subtitle).font(.system(size: 13)).foregroundStyle(Brand.muted(dark)) }.padding(.bottom, 4) }
    var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Brand.line(dark)).frame(height: 1)
            HStack(spacing: 14) {
                Image(systemName: workspace.isRunning ? "arrow.triangle.2.circlepath" : "lock.shield").foregroundStyle(Brand.accent(dark))
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.isRunning ? t("جارٍ تجهيز الملفات…", "Processing files…") : workspace.section == "workspace" ? workspace.tool.title(preferences.arabic) : t("المعالجة محلية", "Entirely local")).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(workspace.pending.isEmpty && !workspace.isRunning ? t("الأصول محفوظة • ⌘K لكل الأدوات", "Originals preserved • ⌘K for all tools") : t("\(workspace.completed) من \(workspace.items.count) مكتمل", "\(workspace.completed) of \(workspace.items.count) completed")).font(.system(size: 10)).foregroundStyle(Brand.muted(dark))
                }
                Spacer(minLength: 8)
                if !workspace.allOutputs.isEmpty { Button { workspace.reveal(workspace.allOutputs) } label: { Image(systemName: "folder").frame(width: 34, height: 34) }.buttonStyle(.plain).help(t("إظهار النتائج", "Show results")) }
                if workspace.isRunning {
                    ProgressView().controlSize(.small)
                    Button(t("إلغاء", "Cancel")) { workspace.cancel() }.buttonStyle(.bordered)
                } else if workspace.section == "workspace" && workspace.pending.isEmpty {
                    Button { workspace.chooseFiles() } label: { Label(t("إضافة ملفات", "Add files"), systemImage: "plus") }.buttonStyle(PrimaryButton()).help("⌘O")
                } else if workspace.section == "workspace" {
                    Button { workspace.start() } label: { HStack(spacing: 10) { Image(systemName: "play.fill"); Text(workspace.failedCount > 0 ? t("إعادة المحاولة", "Retry pending") : t("تنفيذ العملية", "Run job")); Text("\(workspace.pending.count)").font(.system(size: 11, design: .monospaced)) } }.buttonStyle(PrimaryButton()).disabled(!workspace.canRun).help("⌘↩").accessibilityIdentifier("run-job")
                }
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }.background(Brand.surface(dark))
    }
}

struct UpdatesPanel: View {
    @ObservedObject var updater: UpdaterModel
    let arabic: Bool
    let dark: Bool
    var body: some View {
        Panel { VStack(alignment: .leading, spacing: 14) {
            Text(arabic ? "التحديثات" : "Updates").font(.system(size: 13, weight: .semibold))
            if updater.available {
                Toggle(arabic ? "تنزيل التحديثات وتثبيتها تلقائيًا" : "Download and install updates automatically", isOn: $updater.automatic).tint(Brand.accent(dark))
                HStack {
                    Button(arabic ? "التحقق من التحديثات الآن" : "Check for updates now") { updater.check() }.buttonStyle(.bordered).disabled(!updater.canCheck)
                    Spacer()
                    Text("v\(AppInfo.version)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Brand.muted(dark))
                }
                Text(arabic ? "يتحقق التطبيق يوميًا من GitHub. التحديثات موقعة رقميًا، وتُثبت عند إغلاق التطبيق." : "Checks GitHub daily. Updates are signed and install when you quit the app.").font(.system(size: 11)).foregroundStyle(Brand.muted(dark))
            } else {
                Text(arabic ? "التحديث التلقائي متاح في النسخة المنشورة فقط." : "Automatic updates are available in the released app only.").font(.system(size: 11)).foregroundStyle(Brand.muted(dark))
            }
        } }
    }
}

struct QueueRow: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var preferences: Preferences
    @Environment(\.colorScheme) var scheme
    let item: QueueEntry
    var dark: Bool { scheme == .dark }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.symbol).font(.system(size: 20)).foregroundStyle(Brand.accent(dark)).frame(width: 36, height: 40).background(Brand.raised(dark), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: 7) {
                    Text(ByteCountFormatter.string(fromByteCount: item.inputBytes, countStyle: .file))
                    if item.outputBytes > 0 { Image(systemName: "arrow.right"); Text(ByteCountFormatter.string(fromByteCount: item.outputBytes, countStyle: .file)).foregroundStyle(Brand.accent(dark)) }
                    if item.state == .done { Text(String(format: "%.1fs", item.seconds)) }
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.muted(dark)).environment(\.layoutDirection, .leftToRight)
                if !item.detail.isEmpty { Text(item.detail).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(4).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.state == .running { ProgressView().controlSize(.small) }
            else if item.state == .done { Button { workspace.reveal(item.outputs) } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent(dark)) }.buttonStyle(.plain).help(preferences.text("إظهار النتائج في Finder", "Reveal results in Finder")) }
            else if item.state == .failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
            if !workspace.isRunning { Button { workspace.remove(item.id) } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Brand.muted(dark)) }.buttonStyle(.plain).accessibilityLabel(preferences.text("إزالة من القائمة", "Remove from queue")) }
        }.padding(.vertical, 2)
            .contextMenu {
                Button(preferences.text("إظهار الأصل في Finder", "Reveal original in Finder")) { workspace.reveal([item.url]) }
                Button(preferences.text("إظهار النتائج", "Reveal results")) { workspace.reveal(item.outputs) }.disabled(item.outputs.isEmpty)
                Button(preferences.text("نسخ مسار الأصل", "Copy source path")) { workspace.fileAction("path", urls: [item.url]) }
                Divider()
                Button(preferences.text("إزالة من القائمة", "Remove from queue"), role: .destructive) { workspace.remove(item.id) }.disabled(workspace.isRunning)
            }
    }
}
