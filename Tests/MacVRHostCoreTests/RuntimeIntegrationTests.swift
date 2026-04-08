import Darwin
import XCTest
@testable import MacVRHostCore
import MacVRProtocol
@testable import MacVRRuntimeCore
import MacVROpenXRRuntime

final class RuntimeIntegrationTests: XCTestCase {
    private let xrVersionPatch: UInt64 = 57

    private var xrAPIVersion10: XrVersion {
        (1 as UInt64) << 48 | xrVersionPatch
    }

    private var xrCurrentAPIVersion: XrVersion {
        (1 as UInt64) << 48 | (1 as UInt64) << 32 | xrVersionPatch
    }

    func testOpenXRManifestWriterEmitsExpectedShape() throws {
        let json = try OpenXRRuntimeManifest.makeJSON(libraryPath: "/tmp/libMacVROpenXRRuntime.dylib")
        XCTAssertTrue(json.contains("\"file_format_version\" : \"1.0.0\""))
        XCTAssertTrue(json.contains("\"library_path\" : \"/tmp/libMacVROpenXRRuntime.dylib\""))
        XCTAssertTrue(OpenXRRuntimeManifest.suggestedManifestPath().path.hasSuffix(".config/openxr/1/active_runtime.json"))
    }

    func testExperimentalOpenXRRuntimeSupportsHeadlessSessionFlow() throws {
        var loaderInfo = XrNegotiateLoaderInfo(
            structType: XR_LOADER_INTERFACE_STRUCT_LOADER_INFO,
            structVersion: UInt32(XR_LOADER_INFO_STRUCT_VERSION),
            structSize: MemoryLayout<XrNegotiateLoaderInfo>.size,
            minInterfaceVersion: 1,
            maxInterfaceVersion: UInt32(XR_CURRENT_LOADER_RUNTIME_VERSION),
            minApiVersion: xrAPIVersion10,
            maxApiVersion: xrCurrentAPIVersion
        )
        var runtimeRequest = XrNegotiateRuntimeRequest(
            structType: XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST,
            structVersion: UInt32(XR_RUNTIME_INFO_STRUCT_VERSION),
            structSize: MemoryLayout<XrNegotiateRuntimeRequest>.size,
            runtimeInterfaceVersion: 0,
            runtimeApiVersion: 0,
            getInstanceProcAddr: nil
        )

        XCTAssertEqual(xrNegotiateLoaderRuntimeInterface(&loaderInfo, &runtimeRequest), XR_SUCCESS)
        XCTAssertEqual(runtimeRequest.runtimeInterfaceVersion, UInt32(XR_CURRENT_LOADER_RUNTIME_VERSION))
        XCTAssertNotNil(runtimeRequest.getInstanceProcAddr)

        let headlessExtension = strdup(XR_MND_HEADLESS_EXTENSION_NAME)
        defer { free(headlessExtension) }
        let extensionNames: [UnsafePointer<CChar>?] = [UnsafePointer(headlessExtension)]

        var createInfo = XrInstanceCreateInfo()
        createInfo.type = XR_TYPE_INSTANCE_CREATE_INFO
        createInfo.next = nil
        createInfo.createFlags = 0
        createInfo.applicationInfo.apiVersion = xrAPIVersion10
        withUnsafeMutableBytes(of: &createInfo.applicationInfo.applicationName) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            let bytes = Array("macVRTests".utf8)
            for (index, byte) in bytes.enumerated() where index < rawBuffer.count - 1 {
                rawBuffer[index] = byte
            }
        }
        extensionNames.withUnsafeBufferPointer { buffer in
            createInfo.enabledExtensionCount = UInt32(buffer.count)
            createInfo.enabledExtensionNames = buffer.baseAddress
        }

        var instance: XrInstance?
        XCTAssertEqual(xrCreateInstance(&createInfo, &instance), XR_SUCCESS)
        XCTAssertNotNil(instance)
        defer {
            XCTAssertEqual(xrDestroyInstance(instance), XR_SUCCESS)
        }

        var queriedCreateInstance: PFN_xrVoidFunction?
        let createLookupResult = "xrCreateInstance".withCString {
            runtimeRequest.getInstanceProcAddr?(instance, $0, &queriedCreateInstance)
        }
        XCTAssertEqual(createLookupResult, XR_SUCCESS)
        XCTAssertNotNil(queriedCreateInstance)

        var instanceProperties = XrInstanceProperties()
        instanceProperties.type = XR_TYPE_INSTANCE_PROPERTIES
        XCTAssertEqual(xrGetInstanceProperties(instance, &instanceProperties), XR_SUCCESS)
        let runtimeName = withUnsafePointer(to: &instanceProperties.runtimeName.0) { pointer in
            String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
        }
        XCTAssertEqual(runtimeName, String(cString: macvrOpenXRRuntimeName()))

        var systemInfo = XrSystemGetInfo()
        systemInfo.type = XR_TYPE_SYSTEM_GET_INFO
        systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY
        var systemID: XrSystemId = 0
        XCTAssertEqual(xrGetSystem(instance, &systemInfo, &systemID), XR_SUCCESS)
        XCTAssertNotEqual(systemID, 0)

        var viewConfigProps = XrViewConfigurationProperties()
        viewConfigProps.type = XR_TYPE_VIEW_CONFIGURATION_PROPERTIES
        XCTAssertEqual(
            xrGetViewConfigurationProperties(instance, systemID, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, &viewConfigProps),
            XR_SUCCESS
        )
        XCTAssertEqual(viewConfigProps.viewConfigurationType, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)

        var viewCount: UInt32 = 0
        XCTAssertEqual(
            xrEnumerateViewConfigurationViews(instance, systemID, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &viewCount, nil),
            XR_SUCCESS
        )
        XCTAssertEqual(viewCount, 2)

        var sessionCreateInfo = XrSessionCreateInfo()
        sessionCreateInfo.type = XR_TYPE_SESSION_CREATE_INFO
        sessionCreateInfo.systemId = systemID
        var session: XrSession?
        XCTAssertEqual(xrCreateSession(instance, &sessionCreateInfo, &session), XR_SUCCESS)
        XCTAssertNotNil(session)
        defer {
            XCTAssertEqual(xrDestroySession(session), XR_SUCCESS)
        }

        var sessionBeginInfo = XrSessionBeginInfo()
        sessionBeginInfo.type = XR_TYPE_SESSION_BEGIN_INFO
        sessionBeginInfo.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO
        XCTAssertEqual(xrBeginSession(session, &sessionBeginInfo), XR_SUCCESS)
        defer {
            XCTAssertEqual(xrEndSession(session), XR_SUCCESS)
        }

        var referenceSpaceInfo = XrReferenceSpaceCreateInfo()
        referenceSpaceInfo.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO
        referenceSpaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL
        referenceSpaceInfo.poseInReferenceSpace.orientation.w = 1
        var localSpace: XrSpace?
        XCTAssertEqual(xrCreateReferenceSpace(session, &referenceSpaceInfo, &localSpace), XR_SUCCESS)
        XCTAssertNotNil(localSpace)
        defer {
            XCTAssertEqual(xrDestroySpace(localSpace), XR_SUCCESS)
        }

        var frameWaitInfo = XrFrameWaitInfo()
        frameWaitInfo.type = XR_TYPE_FRAME_WAIT_INFO
        var frameState = XrFrameState()
        frameState.type = XR_TYPE_FRAME_STATE
        XCTAssertEqual(xrWaitFrame(session, &frameWaitInfo, &frameState), XR_SUCCESS)
        XCTAssertEqual(frameState.shouldRender, XrBool32(XR_TRUE))

        var frameBeginInfo = XrFrameBeginInfo()
        frameBeginInfo.type = XR_TYPE_FRAME_BEGIN_INFO
        XCTAssertEqual(xrBeginFrame(session, &frameBeginInfo), XR_SUCCESS)

        var viewLocateInfo = XrViewLocateInfo()
        viewLocateInfo.type = XR_TYPE_VIEW_LOCATE_INFO
        viewLocateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO
        viewLocateInfo.displayTime = frameState.predictedDisplayTime
        viewLocateInfo.space = localSpace
        var viewState = XrViewState()
        viewState.type = XR_TYPE_VIEW_STATE
        var locatedViewCount: UInt32 = 0
        var views = [XrView(), XrView()]
        views[0].type = XR_TYPE_VIEW
        views[1].type = XR_TYPE_VIEW
        let locateResult = views.withUnsafeMutableBufferPointer { buffer in
            xrLocateViews(session, &viewLocateInfo, &viewState, UInt32(buffer.count), &locatedViewCount, buffer.baseAddress)
        }
        XCTAssertEqual(locateResult, XR_SUCCESS)
        XCTAssertEqual(locatedViewCount, 2)
        XCTAssertEqual(viewState.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT, XR_VIEW_STATE_POSITION_VALID_BIT)

        var frameEndInfo = XrFrameEndInfo()
        frameEndInfo.type = XR_TYPE_FRAME_END_INFO
        frameEndInfo.displayTime = frameState.predictedDisplayTime
        frameEndInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE
        frameEndInfo.layerCount = 0
        frameEndInfo.layers = nil
        XCTAssertEqual(xrEndFrame(session, &frameEndInfo), XR_SUCCESS)
    }

    func testRuntimeDiscoveryServiceRepliesToProbe() throws {
        let discoveryPort = try availableUDPPort()
        let configuration = RuntimeConfiguration(
            controlPort: 42091,
            bridgePort: 43091,
            jpegInputPort: 44091,
            discoveryPort: discoveryPort,
            serverName: "Test Runtime",
            verbose: false
        )
        let service = RuntimeDiscoveryService(configuration: configuration, logger: HostLogger(verbose: false))
        try service.start()
        defer { service.stop() }

        let announcement = try receiveDiscoveryReply(port: discoveryPort, requestID: "probe-runtime-test")
        XCTAssertEqual(announcement.serverName, "Test Runtime")
        XCTAssertEqual(announcement.controlPort, 42091)
        XCTAssertEqual(announcement.bridgePort, 43091)
        XCTAssertEqual(announcement.jpegInputPort, 44091)
        XCTAssertEqual(announcement.supportedStreamModes, [.bridgeJPEG, .displayJPEG, .mock])
    }

    func testTrustedClientStoreRoundTrip() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macvr-trusted-clients-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = TrustedClientStore(path: fileURL)
        XCTAssertEqual(store.trustedClientCount(), 0)

        let trusted = try store.trust(
            clientName: "macvr-viewer",
            host: "192.168.1.99",
            note: "test-lab headset"
        )
        XCTAssertEqual(trusted.clientName, "macvr-viewer")
        XCTAssertEqual(trusted.host, "192.168.1.99")
        XCTAssertTrue(store.isTrusted(clientName: "macvr-viewer", host: "192.168.1.99"))

        let reloaded = TrustedClientStore(path: fileURL)
        XCTAssertEqual(reloaded.trustedClientCount(), 1)
        XCTAssertEqual(reloaded.trustedClients().first?.note, "test-lab headset")

        XCTAssertTrue(try reloaded.untrust(clientName: "macvr-viewer", host: "192.168.1.99"))
        XCTAssertEqual(reloaded.trustedClientCount(), 0)
    }

    func testRuntimeTrustPolicyDeniesUnknownRemoteWhenStrictTrustEnabled() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macvr-trust-policy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = TrustedClientStore(path: fileURL)
        let policy = RuntimeTrustPolicy(
            requireTrustedClients: true,
            autoTrustLoopbackClients: false,
            trustedClientStore: store,
            logger: HostLogger(verbose: false)
        )
        let identity = ClientIdentity(
            clientName: "macvr-viewer",
            remoteHost: "192.168.1.88",
            requestedFPS: 72,
            requestedStreamMode: .bridgeJPEG
        )

        let denied = policy.authorize(identity)
        if case .deny(let reason) = denied {
            XCTAssertTrue(reason.contains("not trusted"))
        } else {
            XCTFail("Expected strict trust policy to deny untrusted remote identity")
        }
        XCTAssertEqual(policy.deniedCount(), 1)

        _ = try store.trust(clientName: "macvr-viewer", host: "192.168.1.88", note: "manual approval")
        XCTAssertEqual(policy.authorize(identity), .allow)
        XCTAssertEqual(policy.deniedCount(), 1)
    }

    func testExperimentalOpenXRRuntimeReadsTrackingStateFile() throws {
        let trackingStateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macvr-tracking-\(UUID().uuidString).bin")
        let trackingStore = TrackingStateStore(path: trackingStateURL)
        let trackedPose = PosePayload(
            timestampNs: DispatchTime.now().uptimeNanoseconds,
            positionMeters: [0.2, 1.75, -0.4],
            orientationQuaternion: [0.0, 0.38268343, 0.0, 0.9238795]
        )
        try trackingStore.updateHeadPose(trackedPose)

        let previousTrackingStatePath = getenv(TrackingStateStore.environmentVariable).map { String(cString: $0) }
        setenv(TrackingStateStore.environmentVariable, trackingStateURL.path, 1)
        defer {
            if let previousTrackingStatePath {
                setenv(TrackingStateStore.environmentVariable, previousTrackingStatePath, 1)
            } else {
                unsetenv(TrackingStateStore.environmentVariable)
            }
            try? FileManager.default.removeItem(at: trackingStateURL)
        }

        var loaderInfo = XrNegotiateLoaderInfo(
            structType: XR_LOADER_INTERFACE_STRUCT_LOADER_INFO,
            structVersion: UInt32(XR_LOADER_INFO_STRUCT_VERSION),
            structSize: MemoryLayout<XrNegotiateLoaderInfo>.size,
            minInterfaceVersion: 1,
            maxInterfaceVersion: UInt32(XR_CURRENT_LOADER_RUNTIME_VERSION),
            minApiVersion: xrAPIVersion10,
            maxApiVersion: xrCurrentAPIVersion
        )
        var runtimeRequest = XrNegotiateRuntimeRequest(
            structType: XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST,
            structVersion: UInt32(XR_RUNTIME_INFO_STRUCT_VERSION),
            structSize: MemoryLayout<XrNegotiateRuntimeRequest>.size,
            runtimeInterfaceVersion: 0,
            runtimeApiVersion: 0,
            getInstanceProcAddr: nil
        )
        XCTAssertEqual(xrNegotiateLoaderRuntimeInterface(&loaderInfo, &runtimeRequest), XR_SUCCESS)

        let headlessExtension = strdup(XR_MND_HEADLESS_EXTENSION_NAME)
        defer { free(headlessExtension) }
        let extensionNames: [UnsafePointer<CChar>?] = [UnsafePointer(headlessExtension)]

        var createInfo = XrInstanceCreateInfo()
        createInfo.type = XR_TYPE_INSTANCE_CREATE_INFO
        createInfo.applicationInfo.apiVersion = xrAPIVersion10
        withUnsafeMutableBytes(of: &createInfo.applicationInfo.applicationName) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in Array("macVRTrackingTests".utf8).enumerated() where index < rawBuffer.count - 1 {
                rawBuffer[index] = byte
            }
        }
        extensionNames.withUnsafeBufferPointer { buffer in
            createInfo.enabledExtensionCount = UInt32(buffer.count)
            createInfo.enabledExtensionNames = buffer.baseAddress
        }

        var instance: XrInstance?
        XCTAssertEqual(xrCreateInstance(&createInfo, &instance), XR_SUCCESS)
        defer { XCTAssertEqual(xrDestroyInstance(instance), XR_SUCCESS) }

        var systemInfo = XrSystemGetInfo()
        systemInfo.type = XR_TYPE_SYSTEM_GET_INFO
        systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY
        var systemID: XrSystemId = 0
        XCTAssertEqual(xrGetSystem(instance, &systemInfo, &systemID), XR_SUCCESS)

        var sessionCreateInfo = XrSessionCreateInfo()
        sessionCreateInfo.type = XR_TYPE_SESSION_CREATE_INFO
        sessionCreateInfo.systemId = systemID
        var session: XrSession?
        XCTAssertEqual(xrCreateSession(instance, &sessionCreateInfo, &session), XR_SUCCESS)
        defer { XCTAssertEqual(xrDestroySession(session), XR_SUCCESS) }

        var sessionBeginInfo = XrSessionBeginInfo()
        sessionBeginInfo.type = XR_TYPE_SESSION_BEGIN_INFO
        sessionBeginInfo.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO
        XCTAssertEqual(xrBeginSession(session, &sessionBeginInfo), XR_SUCCESS)
        defer { XCTAssertEqual(xrEndSession(session), XR_SUCCESS) }

        var referenceSpaceInfo = XrReferenceSpaceCreateInfo()
        referenceSpaceInfo.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO
        referenceSpaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL
        referenceSpaceInfo.poseInReferenceSpace.orientation.w = 1
        var localSpace: XrSpace?
        XCTAssertEqual(xrCreateReferenceSpace(session, &referenceSpaceInfo, &localSpace), XR_SUCCESS)
        defer { XCTAssertEqual(xrDestroySpace(localSpace), XR_SUCCESS) }

        var location = XrSpaceLocation()
        location.type = XR_TYPE_SPACE_LOCATION
        XCTAssertEqual(xrLocateSpace(localSpace, localSpace, XrTime(DispatchTime.now().uptimeNanoseconds), &location), XR_SUCCESS)
        XCTAssertEqual(location.pose.position.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(location.pose.position.y, 1.75, accuracy: 0.001)
        XCTAssertEqual(location.pose.position.z, -0.4, accuracy: 0.001)
        XCTAssertEqual(location.pose.orientation.y, 0.38268343, accuracy: 0.0001)
        XCTAssertEqual(location.pose.orientation.w, 0.9238795, accuracy: 0.0001)

        var frameWaitInfo = XrFrameWaitInfo()
        frameWaitInfo.type = XR_TYPE_FRAME_WAIT_INFO
        var frameState = XrFrameState()
        frameState.type = XR_TYPE_FRAME_STATE
        XCTAssertEqual(xrWaitFrame(session, &frameWaitInfo, &frameState), XR_SUCCESS)

        var viewLocateInfo = XrViewLocateInfo()
        viewLocateInfo.type = XR_TYPE_VIEW_LOCATE_INFO
        viewLocateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO
        viewLocateInfo.displayTime = frameState.predictedDisplayTime
        viewLocateInfo.space = localSpace
        var viewState = XrViewState()
        viewState.type = XR_TYPE_VIEW_STATE
        var locatedViewCount: UInt32 = 0
        var views = [XrView(), XrView()]
        views[0].type = XR_TYPE_VIEW
        views[1].type = XR_TYPE_VIEW
        let locateViewsResult = views.withUnsafeMutableBufferPointer { buffer in
            xrLocateViews(session, &viewLocateInfo, &viewState, UInt32(buffer.count), &locatedViewCount, buffer.baseAddress)
        }
        XCTAssertEqual(locateViewsResult, XR_SUCCESS)
        XCTAssertEqual(locatedViewCount, 2)
        XCTAssertEqual(views[0].pose.position.y, 1.75, accuracy: 0.001)
        XCTAssertEqual(views[1].pose.position.y, 1.75, accuracy: 0.001)
        XCTAssertEqual(views[0].pose.position.x, 0.2 - 0.0226, accuracy: 0.0015)
        XCTAssertEqual(views[1].pose.position.x, 0.2 + 0.0226, accuracy: 0.0015)
        XCTAssertEqual(views[0].pose.position.z, -0.4 + 0.0226, accuracy: 0.0015)
        XCTAssertEqual(views[1].pose.position.z, -0.4 - 0.0226, accuracy: 0.0015)
    }

    private func availableUDPPort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var address = sockaddr_in()
#if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)

        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.getsockname(fd, rebound, &length)
            }
        }
        XCTAssertEqual(nameResult, 0)
        return UInt16(bigEndian: resolved.sin_port)
    }

    private func receiveDiscoveryReply(port: UInt16, requestID: String) throws -> RuntimeDiscoveryAnnouncement {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        var reuseAddress: Int32 = 1
        XCTAssertEqual(
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size)),
            0
        )
        XCTAssertEqual(
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)),
            0
        )

        var clientAddress = sockaddr_in()
#if os(macOS)
        clientAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
        clientAddress.sin_family = sa_family_t(AF_INET)
        clientAddress.sin_port = 0
        clientAddress.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let bindResult = withUnsafePointer(to: &clientAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)

        let probe = RuntimeDiscoveryProbe(
            requestID: requestID,
            clientName: "macvr-tests",
            requestedStreamMode: .bridgeJPEG
        )
        let encodedProbe = try WireCodec.encode(probe)

        var runtimeAddress = sockaddr_in()
#if os(macOS)
        runtimeAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
        runtimeAddress.sin_family = sa_family_t(AF_INET)
        runtimeAddress.sin_port = port.bigEndian
        XCTAssertEqual(inet_pton(AF_INET, "127.0.0.1", &runtimeAddress.sin_addr), 1)

        let sentBytes = withUnsafePointer(to: &runtimeAddress) { pointer in
            encodedProbe.withUnsafeBytes { rawBuffer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    Darwin.sendto(fd, rawBuffer.baseAddress, rawBuffer.count, 0, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        XCTAssertEqual(sentBytes, encodedProbe.count)

        var buffer = [UInt8](repeating: 0, count: 2048)
        var remoteStorage = sockaddr_storage()
        var remoteLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let bytesRead = withUnsafeMutablePointer(to: &remoteStorage) { pointer in
            buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recvfrom(
                    fd,
                    rawBuffer.baseAddress,
                    rawBuffer.count,
                    0,
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: sockaddr.self),
                    &remoteLength
                )
            }
        }
        XCTAssertGreaterThan(bytesRead, 0)
        return try WireCodec.decode(RuntimeDiscoveryAnnouncement.self, from: Data(buffer[0..<bytesRead]))
    }
}
