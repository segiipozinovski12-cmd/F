import SwiftUI

struct DependencyNoticesView: View {
    var body: some View {
        List {
            Section("libsignal") {
                Text("v0.70.0 · AGPL-3.0-only").font(.headline)
                Text("Официальная библиотека Signal. Интеграция VO1D проверяется отдельно. Исходники и точная версия включены в открытый репозиторий.").font(.caption)
                Link("Исходники libsignal",destination:URL(string:"https://github.com/signalapp/libsignal/tree/efe13e9b363d2c115dba61b76e5e53bbfc2874bc")!)
                NavigationLink("Текст лицензии") { license("LibSignalLicense") }
            }
            Section("Tor") {
                Text("iCepa Tor.framework 409.13.1 · Tor 0.4.9.13")
                Text("Бинарная сборка закреплена контрольной суммой. Обёртка распространяется по MIT; лицензии встроенных компонентов нужно сохранять при распространении.").font(.caption)
                Link("Исходники Tor.framework",destination:URL(string:"https://github.com/iCepa/Tor.framework/tree/51cc492a817bbbc8a647b493d7dde2c0b765ae41")!)
                NavigationLink("Лицензия обёртки") { license("TorWrapperLicense") }
            }
            Section("VO1D") {
                Link("Репозиторий и инструкции сборки",destination:URL(string:"https://github.com/segiipozinovski12-cmd/F")!)
                Text("Независимый аудит и проверки на реальных устройствах не заменяются использованием сторонних библиотек.").font(.caption).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background(.black).navigationTitle("Компоненты")
    }
    private func license(_ name: String) -> some View {
        ScrollView {
            Text(Bundle.main.url(forResource:name,withExtension:"txt").flatMap { try? String(contentsOf:$0,encoding:.utf8) } ?? "Текст лицензии недоступен")
                .font(.caption.monospaced()).textSelection(.enabled).padding(20)
        }.background(.black).navigationTitle("Лицензия")
    }
}
