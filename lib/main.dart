import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity/connectivity.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

typedef void StreamStateCallback(MediaStream stream);

class Signaling {
  void Function()? onCameraInitialized;
  Map<String, dynamic> configuration = {
    'iceServers': [
      {
        'urls': [
          'stun:stun1.l.google.com:19302',
          'stun:stun2.l.google.com:19302'
        ]
      }
    ]
  };

  RTCPeerConnection? peerConnection;
  MediaStream? localStream;
  MediaStream? remoteStream;
  String? roomId;
  StreamStateCallback? onAddRemoteStream;
  //bool to differentiate between caller and callee when reconnecting
  bool isCaller = false;
  //saving renderers to reuse
  RTCVideoRenderer? remoteRenderer;
  RTCVideoRenderer? initialRemoteRenderer;
  //saving firebase listeneres to cancel them when necessary
  StreamSubscription? listenerAnswer;
  StreamSubscription? listenerCalleeCand;
  StreamSubscription? listenerCallerCand;
  //whole implementation takes all kinds of errors into consideration, so it resets stream, here we save last frame
  MediaStream? lastReceivedRemoteStream;
  //Datetome var of when to stop retrying to reconnect
  late DateTime stopTime;

  Future<String> reCreateRoom(RTCVideoRenderer remoteRenderer) async {
    //we cancel listeners to not trigger adding ICE candidates on wrong timing
    listenerAnswer?.cancel();
    listenerCalleeCand?.cancel();
    FirebaseFirestore db = FirebaseFirestore.instance;
    DocumentReference roomRef = db.collection('rooms').doc();

    DocumentReference existingRoomRef = db.collection('rooms').doc(this.roomId);
    var roomSnapshot = await existingRoomRef.get();

    if (roomSnapshot.exists) {
      roomRef = existingRoomRef;
      print('Room already exists. Refreshing data...');
      var batch = FirebaseFirestore.instance.batch();

      batch.update(existingRoomRef, {'offer': FieldValue.delete()});
      batch.update(existingRoomRef, {'answer': FieldValue.delete()});
      await batch.commit();
    } else {
      print("firebase room document cannot be reached");
      return "";
    }
    peerConnection?.close();
    peerConnection = await createPeerConnection(configuration);

    registerPeerConnectionListeners();

    localStream?.getTracks().forEach((track) {
      peerConnection?.addTrack(track, localStream!);
    });

    // Code for collecting ICE candidates below
    var callerCandidatesCollection = roomRef.collection('callerCandidates');

    peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
      callerCandidatesCollection.add(candidate.toMap());
    };
    // Finish Code for collecting ICE candidate

    // Add code for creating a room
    RTCSessionDescription offer = await peerConnection!.createOffer();
    await peerConnection!.setLocalDescription(offer);

    Map<String, dynamic> roomWithOffer = {'offer': offer.toMap()};

    await roomRef.set(roomWithOffer);
    var roomId = roomRef.id;
    this.roomId = roomId;
    // Created a Room

    peerConnection?.onTrack = (RTCTrackEvent event) {
      event.streams[0].getTracks().forEach((track) {
        remoteStream?.addTrack(track);
      });
      lastReceivedRemoteStream = event.streams[0];
    };

    // Listening for remote session description below
    listenerAnswer = roomRef.snapshots().listen((snapshot) async {
      Map<String, dynamic> data = snapshot.data() as Map<String, dynamic>;
      if (peerConnection?.getRemoteDescription() != null &&
          data['answer'] != null) {
        var answer = RTCSessionDescription(
          data['answer']['sdp'],
          data['answer']['type'],
        );

        await peerConnection
            ?.setRemoteDescription(answer)
            .catchError((error) {});
        ;
      }
    });
    // Listening for remote session description above

    // Listen for remote Ice candidates below
    listenerCalleeCand =
        roomRef.collection('calleeCandidates').snapshots().listen((snapshot) {
      snapshot.docChanges.forEach((change) {
        if (change.type == DocumentChangeType.added) {
          Map<String, dynamic> data = change.doc.data() as Map<String, dynamic>;
          peerConnection!
              .addCandidate(
                RTCIceCandidate(
                  data['candidate'],
                  data['sdpMid'],
                  data['sdpMLineIndex'],
                ),
              )
              .catchError((error) {});
        }
      });
    });
    // Listen for remote ICE candidates above
    this.remoteRenderer = remoteRenderer;
    //createRoom means user is caller
    isCaller = true;
    return roomId;
  }

  Future<void> joinRoom(String roomId, RTCVideoRenderer remoteVideo) async {
    //we cancel listeners to not trigger adding ICE candidates on wrong timing
    listenerCallerCand?.cancel();
    peerConnection?.close();

    FirebaseFirestore db = FirebaseFirestore.instance;
    DocumentReference roomRef = db.collection('rooms').doc('$roomId');
    var roomSnapshot = await roomRef.get();

    if (roomSnapshot.exists) {
      peerConnection = await createPeerConnection(configuration);

      registerPeerConnectionListeners();

      localStream?.getTracks().forEach((track) {
        peerConnection?.addTrack(track, localStream!);
      });

      // Code for collecting ICE candidates below
      var calleeCandidatesCollection = roomRef.collection('calleeCandidates');
      peerConnection!.onIceCandidate = (RTCIceCandidate? candidate) {
        if (candidate == null) {
          return;
        }
        calleeCandidatesCollection.add(candidate.toMap());
      };
      // Code for collecting ICE candidate above

      peerConnection?.onTrack = (RTCTrackEvent event) {
        event.streams[0].getTracks().forEach((track) {
          remoteStream?.addTrack(track);
        });
        lastReceivedRemoteStream = event.streams[0];
      };

      // Code for creating SDP answer below
      var data = roomSnapshot.data() as Map<String, dynamic>;
      var offer = data['offer'];
      await peerConnection
          ?.setRemoteDescription(
            RTCSessionDescription(offer['sdp'], offer['type']),
          )
          .catchError((error) {});
      var answer = await peerConnection!.createAnswer();

      await peerConnection!.setLocalDescription(answer).catchError((error) {});

      Map<String, dynamic> roomWithAnswer = {
        'answer': {'type': answer.type, 'sdp': answer.sdp}
      };

      await roomRef.update(roomWithAnswer);
      // Finished creating SDP answer

      // Listening for remote ICE candidates below
      listenerCallerCand =
          roomRef.collection('callerCandidates').snapshots().listen((snapshot) {
        snapshot.docChanges.forEach((document) {
          var data = document.doc.data() as Map<String, dynamic>;
          peerConnection!.addCandidate(
            RTCIceCandidate(
              data['candidate'],
              data['sdpMid'],
              data['sdpMLineIndex'],
            ),
          );
        });
      });
    }
    isCaller = false;
    this.roomId = roomId;
    initialRemoteRenderer = remoteVideo;
  }

  Future<String> createRoom(RTCVideoRenderer remoteRenderer) async {
    //we cancel listeners to not trigger adding ICE candidates on wrong timing
    listenerAnswer?.cancel();
    listenerCalleeCand?.cancel();
    FirebaseFirestore db = FirebaseFirestore.instance;
    DocumentReference roomRef = db.collection('rooms').doc();

    peerConnection?.close();
    peerConnection = await createPeerConnection(configuration);

    registerPeerConnectionListeners();

    localStream?.getTracks().forEach((track) {
      peerConnection?.addTrack(track, localStream!);
    });

    // Code for collecting ICE candidates below
    var callerCandidatesCollection = roomRef.collection('callerCandidates');

    peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
      callerCandidatesCollection.add(candidate.toMap());
    };
    // Finish Code for collecting ICE candidate

    // Add code for creating a room
    RTCSessionDescription offer = await peerConnection!.createOffer();
    await peerConnection!.setLocalDescription(offer);

    Map<String, dynamic> roomWithOffer = {'offer': offer.toMap()};

    await roomRef.set(roomWithOffer);
    var roomId = roomRef.id;
    this.roomId = roomId;
    // Created a Room

    peerConnection?.onTrack = (RTCTrackEvent event) {
      event.streams[0].getTracks().forEach((track) {
        remoteStream?.addTrack(track);
      });
      lastReceivedRemoteStream = event.streams[0];
    };

    // Listening for remote session description below
    listenerAnswer = roomRef.snapshots().listen((snapshot) async {
      Map<String, dynamic> data = snapshot.data() as Map<String, dynamic>;
      if (peerConnection?.getRemoteDescription() != null &&
          data['answer'] != null) {
        var answer = RTCSessionDescription(
          data['answer']['sdp'],
          data['answer']['type'],
        );

        await peerConnection
            ?.setRemoteDescription(answer)
            .catchError((error) {});
        ;
      }
    });
    // Listening for remote session description above

    // Listen for remote Ice candidates below
    listenerCalleeCand =
        roomRef.collection('calleeCandidates').snapshots().listen((snapshot) {
      snapshot.docChanges.forEach((change) {
        if (change.type == DocumentChangeType.added) {
          Map<String, dynamic> data = change.doc.data() as Map<String, dynamic>;
          peerConnection!
              .addCandidate(
                RTCIceCandidate(
                  data['candidate'],
                  data['sdpMid'],
                  data['sdpMLineIndex'],
                ),
              )
              .catchError((error) {});
        }
      });
    });
    // Listen for remote ICE candidates above
    this.remoteRenderer = remoteRenderer;
    //createRoom means user is caller
    isCaller = true;
    return roomId;
  }

  Future<void> openUserMedia(
    RTCVideoRenderer localVideo,
    RTCVideoRenderer remoteVideo,
  ) async {
    await Permission.camera.request();
    await Permission.microphone.request();
    var stream = await navigator.mediaDevices
        .getUserMedia({'video': true, 'audio': true});

    localVideo.srcObject = stream;
    localStream = stream;

    remoteVideo.srcObject = await createLocalMediaStream('key');
    onCameraInitialized?.call();
  }

  Future<void> hangUp(RTCVideoRenderer localVideo) async {
    List<MediaStreamTrack> tracks = localVideo.srcObject!.getTracks();
    tracks.forEach((track) {
      track.stop();
    });

    if (remoteStream != null) {
      remoteStream!.getTracks().forEach((track) => track.stop());
    }
    if (peerConnection != null) peerConnection!.close();

    if (roomId != null) {
      var db = FirebaseFirestore.instance;
      var roomRef = db.collection('rooms').doc(roomId);
      var calleeCandidates = await roomRef.collection('calleeCandidates').get();
      calleeCandidates.docs.forEach((document) => document.reference.delete());

      var callerCandidates = await roomRef.collection('callerCandidates').get();
      callerCandidates.docs.forEach((document) => document.reference.delete());

      await roomRef.delete();
    }

    localStream!.dispose();
    remoteStream?.dispose();
  }

  void registerPeerConnectionListeners() {
    peerConnection?.onIceGatheringState = (RTCIceGatheringState state) {};

    peerConnection?.onConnectionState = (RTCPeerConnectionState state) async {
      print('Connection state change: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        if (lastReceivedRemoteStream != null) {
          // Display last received frame as a still image
          remoteRenderer?.srcObject = lastReceivedRemoteStream;
          initialRemoteRenderer?.srcObject = lastReceivedRemoteStream;
        }
        if (isCaller) {
          // Retry for 30 seconds
          stopTime = DateTime.now().add(Duration(seconds: 30));
          // Continue after connectivity is established
          await waitForConnectivity();
          while (peerConnection!.connectionState !=
                  RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
              DateTime.now().isBefore(stopTime)) {
            print("reCalling");
            await reCreateRoom(remoteRenderer!);
            await Future.delayed(Duration(seconds: getRandomNumber(5, 10)));
            if (peerConnection!.connectionState ==
                RTCPeerConnectionState.RTCPeerConnectionStateConnecting) {
              await Future.delayed(Duration(seconds: 5));
            }
          }
        } else {
          // Retry for 30 seconds
          stopTime = DateTime.now().add(Duration(seconds: 30));
          // Continue after connectivity is established
          await waitForConnectivity();
          while (peerConnection!.connectionState !=
                  RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
              DateTime.now().isBefore(stopTime)) {
            await joinRoom(roomId!, initialRemoteRenderer!);
            await Future.delayed(Duration(seconds: getRandomNumber(5, 10)));
            if (peerConnection!.connectionState ==
                RTCPeerConnectionState.RTCPeerConnectionStateConnecting) {
              await Future.delayed(Duration(seconds: 5));
            }
          }
        }
      }
    };

    peerConnection?.onSignalingState = (RTCSignalingState state) {};

    peerConnection?.onIceGatheringState = (RTCIceGatheringState state) {};

    peerConnection?.onAddStream = (MediaStream stream) {
      onAddRemoteStream?.call(stream);
      remoteStream = stream;
    };
  }

  Future<void> waitForConnectivity() async {
    var connectivityResult = await Connectivity().checkConnectivity();

    // Check if already connected
    if (connectivityResult != ConnectivityResult.none) {
      return; // Already connected, no need to wait
    }

    // Start waiting for connectivity
    print("Waiting for connectivity...");
    await for (var event in Connectivity().onConnectivityChanged) {
      if (event != ConnectivityResult.none) {
        print("Connected to the internet!");
        break; // Break the loop when connected
      }
    }
  }

  int getRandomNumber(int min, int max) {
    final random = Random();
    return min + random.nextInt(max - min);
  }
}
