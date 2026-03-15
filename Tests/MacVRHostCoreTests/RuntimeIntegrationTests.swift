import XCTest
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
}
