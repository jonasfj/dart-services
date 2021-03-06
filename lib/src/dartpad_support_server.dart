// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library services.database;

import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io' as io;
import 'dart:mirrors' as mirrors;

import 'package:appengine/appengine.dart' as ae;
import 'package:crypto/crypto.dart' as crypto;
import 'package:gcloud/db.dart' as db;
import 'package:logging/logging.dart';
import 'package:rpc/rpc.dart';
import 'package:uuid/uuid.dart' as uuid_tools;

final Logger _logger = Logger('dartpad_support_server');

// This class defines the interface that the server provides.
@ApiClass(name: '_dartpadsupportservices', version: 'v1')
class FileRelayServer {
  var database;
  bool test;

  String getTypeName(dynamic obj) =>
      mirrors.reflect(obj).type.reflectedType.toString();

  String getClass(obj) =>
      mirrors.MirrorSystem.getName(mirrors.reflectClass(obj).simpleName);

  FileRelayServer({this.test = false}) {
    hierarchicalLoggingEnabled = true;
    _logger.level = Level.ALL;
    if (this.test) {
      database = Map();
    }
  }

  Future<List> _databaseQuery<T extends db.Model>(
      String attribute, var value) async {
    List result = List();
    if (test) {
      List dataList = database[getClass(T)];
      if (dataList != null) {
        for (var dataObject in dataList) {
          mirrors.InstanceMirror dataObjectMirror = mirrors.reflect(dataObject);
          mirrors.InstanceMirror futureValue =
              dataObjectMirror.getField(Symbol(attribute.split(' ')[0]));
          if (futureValue.hasReflectee && futureValue.reflectee == value) {
            result.add(dataObject);
          }
        }
      }
    } else {
      var query = ae.context.services.db.query<T>()..filter(attribute, value);
      result = await query.run().toList();
    }
    return Future.value(result);
  }

  Future _databaseCommit({List inserts, List deletes}) {
    if (test) {
      if (inserts != null) {
        for (var insertObject in inserts) {
          if (!database.containsKey(getTypeName(insertObject))) {
            database[getTypeName(insertObject)] = List();
          }
          database[getTypeName(insertObject)].add(insertObject);
        }
      }
      if (deletes != null) {
        // TODO: Implement delete
      }
    } else {
      ae.context.services.db.commit(inserts: inserts, deletes: deletes);
    }
    return Future.value(null);
  }

  @ApiMethod(
      method: 'POST',
      path: 'export',
      description: 'Store a gist dataset to be retrieved.')
  Future<UuidContainer> export(PadSaveObject data) {
    _GaePadSaveObject record = _GaePadSaveObject.fromDSO(data);
    String randomUuid = uuid_tools.Uuid().v4();
    record.uuid = "${_computeSHA1(record)}-$randomUuid";
    _databaseCommit(inserts: [record]).catchError((e) {
      _logger.severe("Error while recording export ${e}");
      throw e;
    });
    _logger.info("Recorded Export with ID ${record.uuid}");
    return Future.value(UuidContainer.fromUuid(record.uuid));
  }

  @ApiMethod(
      method: 'POST',
      path: 'pullExportData',
      description: 'Retrieve a stored gist data set.')
  Future<PadSaveObject> pullExportContent(UuidContainer uuidContainer) async {
    List result =
        await _databaseQuery<_GaePadSaveObject>('uuid =', uuidContainer.uuid);
    if (result.isEmpty) {
      _logger
          .severe("Export with UUID ${uuidContainer.uuid} could not be found.");
      throw BadRequestError("Nothing of correct uuid could be found.");
    }
    _GaePadSaveObject record = result.first;
    if (!test) {
      _databaseCommit(deletes: [record.key]).catchError((e) {
        _logger.severe("Error while deleting export ${e}");
        throw (e);
      });
      _logger.info("Deleted Export with ID ${record.uuid}");
    }
    return Future.value(PadSaveObject.fromRecordSource(record));
  }

  @ApiMethod(method: 'GET', path: 'getUnusedMappingId')
  Future<UuidContainer> getUnusedMappingId() async {
    final int limit = 4;
    int attemptCount = 0;
    String randomUuid;
    List result;
    do {
      randomUuid = uuid_tools.Uuid().v4();
      result = await _databaseQuery<_GistMapping>('internalId =', randomUuid);
      attemptCount++;
      if (result.isNotEmpty) {
        _logger.info("Collision in retrieving mapping id ${randomUuid}.");
      }
    } while (result.isNotEmpty && attemptCount < limit);
    if (result.isNotEmpty) {
      _logger.severe("Could not generate valid ID.");
      throw InternalServerError("Could not generate ID.");
    }
    _logger.info("Valid ID ${randomUuid} retrieved.");
    return Future.value(UuidContainer.fromUuid(randomUuid));
  }

  @ApiMethod(method: 'POST', path: 'storeGist')
  Future<UuidContainer> storeGist(GistToInternalIdMapping map) async {
    List result =
        await _databaseQuery<_GistMapping>('internalId =', map.internalId);
    if (result.isNotEmpty) {
      _logger.severe("Collision with mapping of Id ${map.gistId}.");
      throw BadRequestError("Mapping invalid.");
    } else {
      _GistMapping entry = _GistMapping.fromMap(map);
      _databaseCommit(inserts: [entry]).catchError((e) {
        _logger.severe(
            "Error while recording mapping with Id ${map.gistId}. Error ${e}");
        throw e;
      });
      _logger.info("Mapping with ID ${map.gistId} stored.");
      return Future.value(UuidContainer.fromUuid(map.gistId));
    }
  }

  @ApiMethod(method: 'GET', path: 'retrieveGist')
  Future<UuidContainer> retrieveGist({String id}) async {
    if (id == null) {
      throw BadRequestError('Missing parameter: \'id\'');
    }
    List result = await _databaseQuery<_GistMapping>('internalId =', id);
    if (result.isEmpty) {
      _logger.severe("Missing mapping for Id ${id}.");
      throw BadRequestError("Missing mapping for Id ${id}");
    } else {
      _GistMapping entry = result.first;
      _logger.info("Mapping with ID ${id} retrieved.");
      return Future.value(UuidContainer.fromUuid(entry.gistId));
    }
  }
}

/// Public interface object for storage of pads.
class PadSaveObject {
  String dart;
  String html;
  String css;
  String uuid;
  PadSaveObject();

  PadSaveObject.fromData(String dart, String html, String css, {String uuid}) {
    this.dart = dart;
    this.html = html;
    this.css = css;
    this.uuid = uuid;
  }

  PadSaveObject.fromRecordSource(_GaePadSaveObject record) {
    this.dart = record.getDart;
    this.html = record.getHtml;
    this.css = record.getCss;
    this.uuid = record.uuid;
  }
}

/// String container for IDs
class UuidContainer {
  String uuid;
  UuidContainer();
  UuidContainer.fromUuid(String uuid) {
    this.uuid = uuid;
  }
}

/// Map from id to id
class GistToInternalIdMapping {
  String gistId;
  String internalId;
  GistToInternalIdMapping();
  GistToInternalIdMapping.fromIds(String gistId, String internalId) {
    this.gistId = gistId;
    this.internalId = internalId;
  }
}

/// Internal storage representation for storage of pads.
@db.Kind()
class _GaePadSaveObject extends db.Model {
  @db.BlobProperty()
  List<int> dart;

  @db.IntProperty()
  int epochTime;

  @db.BlobProperty()
  List<int> html;

  @db.BlobProperty()
  List<int> css;

  @db.StringProperty()
  String uuid;

  _GaePadSaveObject() {
    this.epochTime = DateTime.now().millisecondsSinceEpoch;
  }

  _GaePadSaveObject.fromData(String dart, String html, String css,
      {String uuid}) {
    this.dart = _gzipEncode(dart);
    this.html = _gzipEncode(html);
    this.css = _gzipEncode(css);
    this.uuid = uuid;
    this.epochTime = DateTime.now().millisecondsSinceEpoch;
  }

  _GaePadSaveObject.fromDSO(PadSaveObject pso) {
    this.dart = _gzipEncode(pso.dart != null ? pso.dart : "");
    this.html = _gzipEncode(pso.html != null ? pso.html : "");
    this.css = _gzipEncode(pso.css != null ? pso.css : "");
    this.uuid = pso.uuid;
    this.epochTime = DateTime.now().millisecondsSinceEpoch;
  }

  String get getDart => _gzipDecode(this.dart);
  String get getHtml => _gzipDecode(this.html);
  String get getCss => _gzipDecode(this.css);
}

/// Internal storage representation for gist id mapping.
@db.Kind()
class _GistMapping extends db.Model {
  @db.StringProperty()
  String internalId;

  @db.StringProperty()
  String gistId;

  @db.IntProperty()
  int epochTime;

  _GistMapping() {
    this.epochTime = DateTime.now().millisecondsSinceEpoch;
  }

  _GistMapping.fromMap(GistToInternalIdMapping map) {
    this.internalId = map.internalId;
    this.gistId = map.gistId;
    this.epochTime = DateTime.now().millisecondsSinceEpoch;
  }
}

String _computeSHA1(_GaePadSaveObject record) {
  convert.Utf8Encoder utf8 = convert.Utf8Encoder();
  return crypto.sha1
      .convert(utf8.convert(
          "blob  'n ${record.getDart} ${record.getHtml} ${record.getCss}"))
      .toString();
}

List<int> _gzipEncode(String input) =>
    io.gzip.encode(convert.utf8.encode(input));
String _gzipDecode(List<int> input) =>
    convert.utf8.decode(io.gzip.decode(input));
