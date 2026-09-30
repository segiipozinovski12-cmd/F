import Foundation

/// Membership versions are inside authenticated Signal messages. Small groups
/// use separate ratchets per recipient, without a shared group decryption key.
enum GroupEpoch {
    static func validate(current: Room, incoming: Room, update: Bool) throws {
        guard current.isGroup else { return }
        let old = current.membershipEpoch ?? 0, next = incoming.membershipEpoch ?? 0
        guard old >= 0, next >= 0, next < Int.max else { throw MessengerError.invalid("Неверная версия группы") }
        if update {
            guard (old == 0 && next == 0) || next > old else { throw MessengerError.invalid("Устаревшее изменение группы") }
        } else {
            guard next == old else { throw MessengerError.invalid("Сначала обнови состав группы") }
        }
    }
}
