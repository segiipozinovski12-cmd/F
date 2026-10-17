import Foundation

struct SessionFence {
    let profileID: String
    let generation: Int
    let identityID: String
}
extension ChatStore {
    var sessionFence: SessionFence { SessionFence(profileID: profileID, generation: generation, identityID: myID) }
    func requireCurrentSession(_ fence: SessionFence) throws {
        guard fence.profileID == profileID, fence.generation == generation, fence.identityID == myID else { throw CancellationError() }
    }
}
