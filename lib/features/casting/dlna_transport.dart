import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dlna_dart/dlna.dart';
import 'package:xml/xml.dart';

import '../../core/server_egress.dart';
import 'dlna_media_request.dart';

const _avTransport = 'urn:schemas-upnp-org:service:AVTransport:1';

class _TransportFault implements Exception {
  const _TransportFault(this.code);

  final int? code;
  bool get mayBeBusy => code == 701 || code == 705;
}

class DlnaTransport {
  DlnaTransport(this.device);

  final DLNADevice device;

  Future<void> play(String url, {required String title}) async {
    final media = dlnaSetMediaRequest(url, title: title);
    try {
      await _request('SetAVTransportURI', body: media);
    } on _TransportFault catch (error) {
      if (!error.mayBeBusy) rethrow;
      await stop();
      await _request('SetAVTransportURI', body: media);
    }
    try {
      await _request('Play', arguments: '<Speed>1</Speed>');
    } catch (_) {
      // SetAVTransportURI already succeeded. Release the partially opened media.
      try {
        await stop();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> stop() async {
    final clock = Stopwatch()..start();
    var stopAccepted = false;
    do {
      if (!stopAccepted) {
        try {
          await _request('Stop');
          stopAccepted = true;
        } on _TransportFault catch (error) {
          if (!error.mayBeBusy) rethrow;
        }
      }
      String? state;
      try {
        state = (await _request('GetTransportInfo')).descendants
            .whereType<XmlElement>()
            .where((node) => node.name.local == 'CurrentTransportState')
            .firstOrNull
            ?.innerText
            .trim();
      } on _TransportFault catch (error) {
        // Some renderers accept Stop but do not implement GetTransportInfo.
        if (stopAccepted && error.code == 401) return;
        if (!error.mayBeBusy) rethrow;
      }
      if (state == 'STOPPED' || state == 'NO_MEDIA_PRESENT') return;
      if (state == null && stopAccepted) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    } while (clock.elapsed < const Duration(seconds: 3));
    throw TimeoutException('DLNA receiver did not stop');
  }

  Future<XmlDocument> _request(
    String action, {
    List<int>? body,
    String arguments = '',
  }) async {
    final renderer = Uri.parse(device.info.URLBase);
    final uri = Uri.parse(device.controlURL('AVTransport'));
    if (!ServerEgress.isLocal(uri) ||
        uri.host != renderer.host ||
        uri.port != renderer.port ||
        uri.scheme != renderer.scheme) {
      throw StateError('無法確認投屏設備的局域網地址。');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      return await (() async {
        final request = await client.postUrl(uri);
        request.followRedirects = false;
        request.headers.contentType = ContentType(
          'text',
          'xml',
          charset: 'utf-8',
        );
        request.headers.set('SOAPAction', '"$_avTransport#$action"');
        final payload =
            body ??
            utf8.encode(
              '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
              's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
              '<s:Body><u:$action xmlns:u="$_avTransport">'
              '<InstanceID>0</InstanceID>$arguments</u:$action></s:Body></s:Envelope>',
            );
        request.contentLength = payload.length;
        request.add(payload);
        final response = await request.close();
        final source = await utf8.decoder.bind(response).join();
        XmlDocument? xml;
        try {
          xml = XmlDocument.parse(source);
        } on XmlException {
          if (response.statusCode == HttpStatus.ok) rethrow;
        }
        int? errorCode;
        var fault = false;
        for (final node
            in xml?.descendants.whereType<XmlElement>() ?? <XmlElement>[]) {
          if (node.name.local == 'Fault') fault = true;
          if (node.name.local == 'errorCode') {
            errorCode = int.tryParse(node.innerText.trim());
          }
        }
        if (response.statusCode != HttpStatus.ok ||
            fault ||
            errorCode != null) {
          throw _TransportFault(errorCode);
        }
        return xml!;
      })().timeout(const Duration(seconds: 3));
    } finally {
      client.close(force: true);
    }
  }
}
