import SwiftUI
import UIKit
import Vision
import CoreImage

struct PhotoDraft: Identifiable {
    var id = UUID()
    var data: Data
    var seconds: Int?
}

struct FileReview: Identifiable {
    var id = UUID()
    var data: Data
    var mime: String
    var name: String
    var warnings: [String]
}

struct FileReviewView: View {
    let review: FileReview
    let send: (Data,String,String) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var cleanPhoto = true
    var body: some View {
        NavigationStack {
            Form {
                Section("Проверь перед отправкой") {
                    Text(review.name)
                    ForEach(review.warnings,id:\.self) { Text($0).font(.caption) }
                    Text("Проверка не гарантирует обнаружение всех личных данных. Внутри самого документа могут быть имена, адреса и другая информация.")
                        .font(.caption).foregroundStyle(.secondary)
                    if review.mime.hasPrefix("image/") { Toggle("Пересобрать фото без EXIF",isOn:$cleanPhoto) }
                }
                Button("Отправить") {
                    if cleanPhoto,review.mime.hasPrefix("image/"),let image=UIImage(data:review.data) {
                        let format=UIGraphicsImageRendererFormat(); format.scale=1
                        let rendered=UIGraphicsImageRenderer(size:image.size,format:format).image { _ in image.draw(at:.zero) }
                        if let data=rendered.jpegData(compressionQuality:0.85) { send(data,"image/jpeg","Photo.jpg") }
                    } else { send(review.data,review.mime,review.name) }
                    dismiss()
                }
            }.navigationTitle("Метаданные файла").toolbar { Button("Отмена") { dismiss() } }
        }
    }
}

struct PhotoPrivacyEditor: View {
    let draft: PhotoDraft
    let send: (Attachment) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var masks: [CGRect] = []
    @State private var style = "black"
    @State private var recognized = ""
    @State private var processing = false
    private var image: UIImage? { UIImage(data:draft.data) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:18) {
                    if let image {
                        let aspect=image.size.width/max(1,image.size.height)
                        GeometryReader { geometry in
                            ZStack {
                                Image(uiImage:image).resizable().scaledToFit()
                                ForEach(Array(masks.enumerated()),id:\.offset) { _,rect in
                                    Rectangle().fill(.black.opacity(style=="black" ? 1 : 0.65))
                                        .frame(width:rect.width*geometry.size.width,height:rect.height*geometry.size.height)
                                        .position(x:rect.midX*geometry.size.width,y:rect.midY*geometry.size.height)
                                }
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance:4).onEnded { value in
                                let x=max(0,min(value.startLocation.x,value.location.x))/geometry.size.width
                                let y=max(0,min(value.startLocation.y,value.location.y))/geometry.size.height
                                let w=min(1-x,abs(value.translation.width)/geometry.size.width)
                                let h=min(1-y,abs(value.translation.height)/geometry.size.height)
                                if w>0.005 && h>0.005 { masks.append(CGRect(x:x,y:y,width:w,height:h)) }
                            })
                        }.aspectRatio(aspect,contentMode:.fit)
                        Text("Выдели пальцем лицо, номер или другой фрагмент. Изменения будут записаны в отправленное фото.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Скрыть фрагменты",selection:$style) {
                            Text("Закрасить").tag("black"); Text("Размыть").tag("blur")
                        }.pickerStyle(.segmented)
                        HStack {
                            Button("Найти лица") { detectFaces() }
                            Button("Отменить выделение") { if !masks.isEmpty { masks.removeLast() } }
                        }.buttonStyle(.bordered)
                        Button(processing ? "Распознавание…" : "Прочитать текст на фото локально") {
                            processing=true
                            Task {
                                do { recognized=try await Task.detached { try SafeContent.recognizeText(draft.data) }.value }
                                catch { recognized="Не удалось распознать текст" }
                                processing=false
                            }
                        }.disabled(processing)
                        if !recognized.isEmpty { Text(recognized).font(.caption).textSelection(.enabled) }
                        Button("ОТПРАВИТЬ ФОТО") {
                            if let attachment=render(image) { send(attachment); dismiss() }
                        }.buttonStyle(PrimaryButton())
                    }
                }.padding(20)
            }.navigationTitle("Приватность фото").toolbar { Button("Отмена") { dismiss() } }
        }
    }

    private func detectFaces() {
        let request=VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(data:draft.data).perform([request])
            for face in request.results ?? [] {
                let r=face.boundingBox
                masks.append(CGRect(x:max(0,r.minX-0.02),y:max(0,1-r.maxY-0.02),
                    width:min(1-r.minX,r.width+0.04),height:min(1-(1-r.maxY),r.height+0.04)))
            }
        } catch { recognized="Не удалось найти лица. Выдели область вручную." }
    }

    private func render(_ image: UIImage) -> Attachment? {
        let format=UIGraphicsImageRendererFormat(); format.scale=1
        let size=image.size
        var blurred: UIImage?
        if style=="blur",let input=CIImage(image:image),
           let filter=CIFilter(name:"CIGaussianBlur",parameters:[kCIInputImageKey:input.clampedToExtent(),kCIInputRadiusKey:40]),
           let output=filter.outputImage?.cropped(to:input.extent),
           let cg=CIContext().createCGImage(output,from:input.extent) { blurred=UIImage(cgImage:cg) }
        let result=UIGraphicsImageRenderer(size:size,format:format).image { context in
            image.draw(in:CGRect(origin:.zero,size:size))
            for mask in masks {
                let rect=CGRect(x:mask.minX*size.width,y:mask.minY*size.height,width:mask.width*size.width,height:mask.height*size.height)
                if let blurred {
                    context.cgContext.saveGState(); context.cgContext.clip(to:rect)
                    blurred.draw(in:CGRect(origin:.zero,size:size)); context.cgContext.restoreGState()
                } else { UIColor.black.setFill(); context.cgContext.fill(rect) }
            }
        }
        guard let jpeg=result.jpegData(compressionQuality:0.8) else { return nil }
        return Attachment(name:"Photo.jpg",mime:"image/jpeg",data:jpeg,viewSeconds:draft.seconds)
    }
}

struct MessageDetailsView: View {
    let message: ChatMessage
    @EnvironmentObject var store: ChatStore
    var body: some View {
        List {
            Section("Сообщение") {
                LabeledContent("Создано", value: message.createdAt.formatted())
                LabeledContent("Состояние", value: statusTitle)
                if pendingCount > 0 {
                    LabeledContent("Ожидает отправки", value: "\(pendingCount)")
                }
                if issueCount > 0 {
                    LabeledContent("Ошибки доставки", value: "\(issueCount)")
                        .foregroundStyle(.orange)
                }
            }
            Section("Получатели") {
            ForEach(store.state.rooms.first { $0.id==message.roomID }?.members.filter { $0.id != store.myID } ?? []) { member in
                HStack {
                    Text(store.name(member.id)); Spacer()
                    Text(message.readBy.contains(member.id) ? "Прочитано" : message.deliveredTo.contains(member.id) ? "Доставлено" : "Нет подтверждения")
                        .font(.caption)
                }
            }
            }
            Section {
                Text("Отсутствие подтверждения не доказывает, что сообщение не получено: собеседник может отключить статусы.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Доставка сообщения")
    }

    private var pending: [PendingDelivery] { store.state.outbox.filter { $0.messageID == message.id } }
    private var pendingCount: Int { pending.count }
    private var issueCount: Int { pending.filter { store.deliveryIssues[$0.id] != nil }.count }
    private var statusTitle: String {
        switch message.state {
        case "scheduled": return "Запланировано"
        case "queued": return issueCount > 0 ? "Повторная отправка" : "В очереди"
        case "sent": return "Передано relay"
        case "delivered": return "Доставлено"
        case "read": return "Прочитано"
        case "failed": return "Ошибка"
        case "cancelled": return "Отменено"
        default: return "Ожидает"
        }
    }
}
