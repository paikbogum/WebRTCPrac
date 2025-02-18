//
//  ViewController.swift
//  WebRTC2
//
//  Created by 백현진 on 2/17/25.
//

import UIKit
import WebRTC
import Network
import AVFoundation

class ViewController: UIViewController {
    
    // MARK: - WebRTC 관련 프로퍼티
    private var peerConnectionFactory: RTCPeerConnectionFactory!
    private var localPeerConnection: RTCPeerConnection?
    private var localVideoTrack: RTCVideoTrack?
    private var localVideoCapturer: RTCCameraVideoCapturer?
    
    // 로컬 미리보기
    private var localRenderView: RTCMTLVideoView = {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.backgroundColor = .black
        return view
    }()
    
    // MARK: - WebSocket 관련
    private var webSocketTask: URLSessionWebSocketTask?
    
    // 시그널링 서버 주소 (동일 Wi-Fi 상의 PC IP로 교체)
    private let signalingServerURL = URL(string: "wss://port-0-aicam-m23f9wqsb6deeb9e.sel4.cloudtype.app/signal")!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .white
        
        // 델리게이트 지정
        localRenderView.delegate = self
        
        setupViews()
        setupWebRTC()
        startCaptureLocalVideo()
        
        // 시그널링 서버(WebSocket)에 연결
        connectWebSocket()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.printLegacyStats()
        }
    }
    
    func printLegacyStats() {
        localPeerConnection?.stats(for: nil, statsOutputLevel: .standard, completionHandler: { reports in
            for report in reports {
                print("=== RTCLegacyStatsReport ===")
                print("type: \(report.type), id: \(report.reportId), timestamp: \(report.timestamp)")
                // Values
                for v in report.values {
                    print("  \(v.key) = \(v.value)")
                }
            }
        })
    }
    
    // 레이아웃 세팅
    private func setupViews() {
        view.addSubview(localRenderView)
        localRenderView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            localRenderView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            localRenderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            localRenderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            localRenderView.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 4.0/3.0)
        ])
    }
    
    
    // MARK: - WebRTC 초기화
    private func setupWebRTC() {
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        
        peerConnectionFactory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan
        
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        
        localPeerConnection = peerConnectionFactory.peerConnection(with: config, constraints: constraints, delegate: self)
    }
    
    // MARK: - 카메라 캡처 시작
    
    /// 주어진 `width`, `height`에 가장 가까운 해상도를 가지는 AVCaptureDevice.Format을 찾는다.
    func findClosestFormat(for device: AVCaptureDevice, targetWidth: Int32, targetHeight: Int32) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        var bestFormat: AVCaptureDevice.Format?
        var smallestDiff = Int.max
        
        for format in formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            // 차이값(가로+세로 오차)을 계산
            let diff = abs(Int(dims.width) - Int(targetWidth)) + abs(Int(dims.height) - Int(targetHeight))
            if diff < smallestDiff {
                bestFormat = format
                smallestDiff = diff
            }
        }
        
        return bestFormat
    }
    
    private func startCaptureLocalVideo() {
        // 1) 비디오 소스 & 카메라 캡처러
        let videoSource = peerConnectionFactory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        localVideoCapturer = capturer
        
        // 2) 전면 카메라(없으면 첫 번째)
        guard let device = RTCCameraVideoCapturer.captureDevices()
            .first(where: { $0.position == .front })
            ?? RTCCameraVideoCapturer.captureDevices().first else {
            print("카메라 디바이스가 없습니다.")
            return
        }
        
        // 3) 원하는 해상도 근처(640×480) 포맷 선택
        guard let format = findClosestFormat(for: device, targetWidth: 640, targetHeight: 480) else {
            print("640×480 근처 해상도 포맷을 찾을 수 없습니다.")
            return
        }
        
        // (확인용) 실제 포맷 정보 출력
        let desc = format.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        print("선택된 카메라 포맷 해상도: \(dims.width)x\(dims.height)")
        
        // 4) FPS 설정 (예: 최대 30)
        let fpsRange = format.videoSupportedFrameRateRanges.first
        let maxFps = fpsRange?.maxFrameRate ?? 5
        let targetFps = min(5, maxFps)

        // 5) 카메라 캡처 시작
        capturer.startCapture(with: device, format: format, fps: Int(targetFps))
        
        // 6) 소프트웨어 스케일링으로 최종 640×640, 30fps 출력
        videoSource.adaptOutputFormat(toWidth: 640, height: 640, fps: 5)
        
        // 7) 비디오 트랙 생성
        let track = peerConnectionFactory.videoTrack(with: videoSource, trackId: "ARDAMSv0")
        localVideoTrack = track
        
        // 미리보기 뷰에 연결
        track.add(localRenderView)
        
        // 8) PeerConnection에 트랙 추가
        let streamId = "stream0"
        if let sender = localPeerConnection?.add(track, streamIds: [streamId]) {
            // 9) 비트레이트 제한 높게 설정
            var parameters = sender.parameters
            if var encoding = parameters.encodings.first {
                // 예: 최대 2.5Mbps, 최소 800kbps
                encoding.maxBitrateBps = NSNumber(value: 2_500_000)
                encoding.minBitrateBps = NSNumber(value: 1_000_000)
                parameters.encodings[0] = encoding
            }
            sender.parameters = parameters
        }
    }

    
    // MARK: - WebSocket 연결
     private func connectWebSocket() {
         let session = URLSession(configuration: .default)
         webSocketTask = session.webSocketTask(with: signalingServerURL)
         webSocketTask?.resume()
         
         // 서버로부터 오는 메시지(Offer, Answer, ICE Candidate 등)를 수신
         listenWebSocketMessages()
         
         // 연결 후 바로 Offer를 생성해서 보낼 수도 있음(시나리오에 따라 다름)
         // 여기서는 "방금 연결되었으니 offer를 보낸다"는 가정
         createOffer()
     }
    
    private func listenWebSocketMessages() {
        webSocketTask?.receive(completionHandler: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("WebSocket 수신 에러: \(error.localizedDescription)")
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleSignalingMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleSignalingMessage(text)
                    }
                @unknown default:
                    break
                }
                
                // 다시 수신 대기
                self.listenWebSocketMessages()
            }
        })
    }
    
    private func handleSignalingMessage(_ text: String) {
        guard let jsonData = text.data(using: .utf8) else { return }
        do {
            if let dict = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                if let type = dict["type"] as? String {
                    switch type {
                    case "offer":
                        if let sdp = dict["sdp"] as? String {
                            receiveOffer(fromRemote: sdp)
                        }
                    case "answer":
                        if let sdp = dict["sdp"] as? String {
                            receiveAnswer(fromRemote: sdp)
                        }
                    case "candidate":
                        if let sdpMid = dict["sdpMid"] as? String,
                           let sdpMLineIndex = dict["sdpMLineIndex"] as? Int32,
                           let candidate = dict["candidate"] as? String {
                            let iceCandidate = RTCIceCandidate(
                                sdp: candidate,
                                sdpMLineIndex: sdpMLineIndex,
                                sdpMid: sdpMid
                            )
                            localPeerConnection?.add(iceCandidate)
                        }
                    default:
                        break
                    }
                }
            }
        } catch {
            print("시그널링 메시지 JSON 파싱 오류: \(error)")
        }
    }
    
    
    // WebSocket으로 시그널링 메시지 전송
     private func sendSignalMessage(_ dict: [String: Any]) {
         guard let webSocketTask = webSocketTask else { return }
         
         do {
             let data = try JSONSerialization.data(withJSONObject: dict, options: [])
             let text = String(data: data, encoding: .utf8) ?? ""
             webSocketTask.send(.string(text)) { error in
                 if let error = error {
                     print("WebSocket 메시지 전송 에러: \(error)")
                 }
             }
         } catch {
             print("JSON 직렬화 에러: \(error)")
         }
     }
    
    // MARK: - Offer/Answer
     /*
     private func createOffer() {
         let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                               optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
         
         localPeerConnection?.offer(for: constraints, completionHandler: { [weak self] sdp, error in
             guard let self = self else { return }
             if let error = error {
                 print("Offer 생성 실패: \(error.localizedDescription)")
                 return
             }
             guard let sdp = sdp else { return }
             
             // **여기에서 Offer SDP 문자열을 출력**
             print("Offer SDP:\n\(sdp.sdp)")
             
             self.localPeerConnection?.setLocalDescription(sdp, completionHandler: { error in
                 if let error = error {
                     print("setLocalDescription(offer) 실패: \(error.localizedDescription)")
                     return
                 }
                 // WebSocket을 통해 Offer SDP 전송
                 let message: [String: Any] = [
                     "type": "offer",
                     "sdp": sdp.sdp
                 ]
                 self.sendSignalMessage(message)
             })
         })
     }*/
    
    private func createOffer() {
        let offerConstraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                                   optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
        
        localPeerConnection?.offer(for: offerConstraints) { [weak self] sdp, error in
            guard let self = self else { return }
            if let error = error {
                print("Offer 생성 실패: \(error.localizedDescription)")
                return
            }
            guard let sdp = sdp else { return }
            
            // 1) 오리지널 SDP 추출
            let originalSDP = sdp.sdp
            
            // 2) RTX 라인만 제거
            let mungedSDP = self.removeRTX(from: originalSDP)
            
            // 3) 새로운 SDP 객체 생성
            let newSdp = RTCSessionDescription(type: .offer, sdp: mungedSDP)
            
            // 4) 로컬에 설정
            self.localPeerConnection?.setLocalDescription(newSdp) { error in
                if let error = error {
                    print("setLocalDescription(offer) 실패: \(error.localizedDescription)")
                    return
                }
                
                // 5) 시그널링으로 전송
                let msg: [String: Any] = [
                    "type": "offer",
                    "sdp": newSdp.sdp
                ]
                self.sendSignalMessage(msg)
            }
        }
    }
    
    /// SDP에서 `video/rtx` 관련 페이로드만 제거한 새 SDP를 반환한다.
    func removeRTX(from sdp: String) -> String {
        var lines = sdp.components(separatedBy: "\n")
        
        // 1) rtx PT 식별
        //    예: a=rtpmap:<payloadType> rtx/90000
        //    -> <payloadType>를 찾아 rtxPTs에 추가
        var rtxPTs = [String]()
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("a=rtpmap:") && lower.contains("rtx/") {
                // 예: "a=rtpmap:98 rtx/90000"
                // -> payloadType = "98"
                if let startRange = line.range(of: "a=rtpmap:") {
                    let after = line[startRange.upperBound...]  // "98 rtx/90000" 부분
                    if let spaceIndex = after.firstIndex(of: " ") {
                        let pt = after[..<spaceIndex] // "98"
                        rtxPTs.append(String(pt))
                    }
                }
            }
        }
        
        // 2) rtx PT와 연관된 a=fmtp / a=rtcp-fb / rtpmap 라인 제거
        //    + m=video 라인에서 rtx PT 번호 제거
        //    (아래는 2-pass로 나누어 처리)
        
        // (A) 먼저 불필요한 a= 라인 제거
        var filteredLines = [String]()
        for line in lines {
            let lower = line.lowercased()
            
            // rtx PT를 참조하는 a=rtpmap / a=fmtp / a=rtcp-fb 등 제거
            // 예: a=rtpmap:98 rtx/90000, a=fmtp:98 apt=96 ...
            //     a=rtcp-fb:98 nack ...
            
            // 만약 라인이 rtx PT 중 하나와 "a=<something>:<pt>" 형태로 매칭되면 제거
            var shouldRemove = false
            
            for pt in rtxPTs {
                // "a=rtpmap:<pt>", "a=fmtp:<pt>", "a=rtcp-fb:<pt>" 등
                // line 예: "a=rtpmap:98 rtx/90000"
                //          "a=fmtp:98 apt=96"
                //          "a=rtcp-fb:98 nack"
                if lower.hasPrefix("a=rtpmap:\(pt)") ||
                   lower.hasPrefix("a=fmtp:\(pt)") ||
                   lower.hasPrefix("a=rtcp-fb:\(pt)") {
                    shouldRemove = true
                    break
                }
            }
            
            if !shouldRemove {
                filteredLines.append(line)
            }
        }
        
        // (B) 이제 m=video 라인에서 rtx PT 제거
        //     m=video는 보통 "m=video 9 RTP/SAVPF 96 97 98 ..." 처럼 paylaodType 나열
        var newLines = [String]()
        
        for line in filteredLines {
            if line.lowercased().hasPrefix("m=video") {
                // e.g. "m=video 9 RTP/SAVPF 96 97 98"
                var parts = line.components(separatedBy: " ")
                // parts[0] = "m=video"
                // parts[1] = port(또는 9)
                // parts[2] = 프로토콜("RTP/SAVPF" 등)
                // parts[3...] = 나머지 PT들
                
                if parts.count > 3 {
                    // header: m=video, port, protocol
                    let header = parts[0..<3]
                    let pts = parts[3...] // payload types
                    
                    // rtx PT가 아닌 애들만 필터
                    let filteredPTs = pts.filter { !rtxPTs.contains($0) }
                    
                    // 최종 합침
                    parts = Array(header) + Array(filteredPTs)
                }
                newLines.append(parts.joined(separator: " "))
            } else {
                newLines.append(line)
            }
        }
        
        // 결과 합치기
        return newLines.joined(separator: "\n")
    }
     
     private func createAnswer() {
         let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                               optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
         
         localPeerConnection?.answer(for: constraints, completionHandler: { [weak self] sdp, error in
             guard let self = self else { return }
             if let error = error {
                 print("Answer 생성 실패: \(error.localizedDescription)")
                 return
             }
             guard let sdp = sdp else { return }
             
             self.localPeerConnection?.setLocalDescription(sdp, completionHandler: { error in
                 if let error = error {
                     print("setLocalDescription(answer) 실패: \(error.localizedDescription)")
                     return
                 }
                 let message: [String: Any] = [
                     "type": "answer",
                     "sdp": sdp.sdp
                 ]
                 self.sendSignalMessage(message)
             })
         })
     }
     
     // 원격에서 Offer를 받은 경우 -> Answer 생성
     func receiveOffer(fromRemote offerSdp: String) {
         let remoteSdp = RTCSessionDescription(type: .offer, sdp: offerSdp)
         localPeerConnection?.setRemoteDescription(remoteSdp, completionHandler: { [weak self] error in
             guard let self = self else { return }
             if let error = error {
                 print("remote offer set 실패: \(error.localizedDescription)")
                 return
             }
             // Offer를 세팅한 후 Answer를 생성해 전송
             self.createAnswer()
         })
     }
     
     // 원격에서 Answer를 받은 경우
     func receiveAnswer(fromRemote answerSdp: String) {
         let remoteSdp = RTCSessionDescription(type: .answer, sdp: answerSdp)
         localPeerConnection?.setRemoteDescription(remoteSdp, completionHandler: { error in
             if let error = error {
                 print("remote answer set 실패: \(error.localizedDescription)")
             } else {
                 print("원격 SDP(Answer) 설정 성공!")
             }
         })
     }
 }

    
// MARK: - RTCPeerConnectionDelegate
extension ViewController: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("Signaling state: \(stateChanged.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("원격 스트림 추가됨: \(stream.streamId)")
        // 여기서 원격 비디오/오디오 트랙을 가져올 수 있음
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("원격 스트림 제거됨: \(stream.streamId)")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("네고시에이션 필요")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("ICE connection state: \(newState.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("ICE gathering state: \(newState.rawValue)")
    }
    
    // 로컬에서 ICE Candidate가 생성되면 -> 웹소켓으로 상대방에게 candidate 정보 전송
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("Local ICE candidate: \(candidate.sdp)")
        let message: [String: Any] = [
            "type": "candidate",
            "candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? "",
            "sdpMLineIndex": candidate.sdpMLineIndex
        ]
        sendSignalMessage(message)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print("ICE candidates removed: \(candidates)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("DataChannel 열림: \(dataChannel.label)")
    }
}

extension ViewController: RTCVideoViewDelegate {
    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        // 이 콜백은 "새 프레임 해상도"가 달라졌을 때 호출
        print("Local video size changed to: \(Int(size.width)) x \(Int(size.height))")
    }
}
