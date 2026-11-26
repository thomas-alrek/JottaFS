import Foundation

/// Removing a location (to the trash) or deleting a whole backup device:
/// the affected mounted locations are unmounted first, one by one, and the
/// removal runs only when every one of them is unmounted. If an unmount
/// fails (a file on the disk is still open), nothing is removed and the
/// error is passed on; locations already unmounted stay unmounted.
public enum LocationRemoval {
    public static func run<Location: Sendable>(
        unmounting mounted: [Location],
        unmount: (Location) async throws -> Void,
        remove: () async throws -> Void
    ) async throws {
        for location in mounted {
            try await unmount(location)
        }
        try await remove()
    }
}
