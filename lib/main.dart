import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ping App',
      home: Scaffold(
        backgroundColor: Colors.orange,
        body: const MyHomePage(),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key}) : super(key: key);

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String? tcNumber;
  Timer? _timer;
  Database? _database;
  List<Map<String, dynamic>> _pendingRecords = [];

  @override
  void initState() {
    super.initState();
    initializeApp();
  }

  Future<void> initializeApp() async {
    await _initDB();
    await _loadTCNumber();
    _requestPermissions();
    _startPingTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _initDB() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = "${directory.path}/pingresults.db";
    _database = await openDatabase(path, version: 1, onCreate: (Database db, int version) async {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS Results (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ipAddress TEXT NOT NULL,
          unixTime INTEGER NOT NULL,
          latitude REAL NOT NULL,
          longitude REAL NOT NULL,
          tcNumber TEXT NOT NULL,
          statusCode INTEGER NOT NULL
        );
      ''');
    });
  }

  Future<void> _loadTCNumber() async {
    final prefs = await SharedPreferences.getInstance();
    final storedTCNumber = prefs.getString('tcNumber');
    if (storedTCNumber == null) {
      WidgetsBinding.instance!.addPostFrameCallback((_) => _showTCNumberInput());
    } else {
      tcNumber = storedTCNumber;
    }
  }

  void _startPingTimer() {
    const String ipAddress = '8.8.8.8'; // Google's DNS for example
    _timer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (tcNumber != null) {
        await _ping(ipAddress);
      }
    });
  }

  Future<void> _ping(String ipAddress) async {
    try {
      final response = await http.get(Uri.parse('http://$ipAddress'));
      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final int unixTime = DateTime.now().millisecondsSinceEpoch;
      await _database!.insert('Results', {
        'ipAddress': ipAddress,
        'unixTime': unixTime,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'tcNumber': tcNumber!,
        'statusCode': response.statusCode
      });
      print('Ping successful: IP Address: $ipAddress, Unix Time: $unixTime, Latitude: ${position.latitude}, Longitude: ${position.longitude}, TC Number: $tcNumber, Status Code: ${response.statusCode}');

      // Si el número total de registros almacenados es un múltiplo de 5, o sea, si el residuo de dividir entre 5 es 0
      if ((_pendingRecords.length + 1) % 5 == 0) {
        print('Mensaje impreso después de almacenar cada conjunto de 5 registros');
        await _sendPendingRecords(); // Envía los registros pendientes
      }

      // Incrementa el contador de registros almacenados
      _pendingRecords.add({
        'ipAddress': ipAddress,
        'unixTime': unixTime,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'tcNumber': tcNumber!,
        'statusCode': response.statusCode
      });
    } catch (e) {
      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final int unixTime = DateTime.now().millisecondsSinceEpoch;
      print('Storing data even though ping failed: IP Address: $ipAddress, Unix Time: $unixTime, Latitude: ${position.latitude}, Longitude: ${position.longitude}, TC Number: $tcNumber, Status Code: Not available due to ping failure');
      if (_database != null) {
        await _database!.insert('Results', {
          'ipAddress': ipAddress,
          'unixTime': unixTime,
          'latitude': position.latitude,
          'longitude': position.longitude,
          'tcNumber': tcNumber!,
          'statusCode': -1 // Indicador de falla de ping
        });
      }

      // Si el número total de registros almacenados es un múltiplo de 5, o sea, si el residuo de dividir entre 5 es 0
      if ((_pendingRecords.length + 1) % 5 == 0) {
        print('Mensaje impreso después de almacenar cada conjunto de 5 registros');
        await _sendPendingRecords(); // Envía los registros pendientes
      }

      // Incrementa el contador de registros almacenados
      _pendingRecords.add({
        'ipAddress': ipAddress,
        'unixTime': unixTime,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'tcNumber': tcNumber!,
        'statusCode': -1 // Indicador de falla de ping
      });
    }
  }

  Future<List<Map<String, dynamic>>> _getLastFiveRecords() async {
    // Verificar si la base de datos está inicializada
    if (_database == null) {
      print('Error: La base de datos no está inicializada.');
      return [];
    }

    try {
      // Consultar los últimos cinco registros de la base de datos
      List<Map<String, dynamic>> records = await _database!.query(
        'Results',
        orderBy: 'id DESC',
        limit: 5,
      );

      return records;
    } catch (e) {
      print('Error al consultar los últimos cinco registros: $e');
      return [];
    }
  }

  Future<void> _sendPendingRecords() async {
    print('Enviando registros pendientes...');

    // Obtener los últimos 5 registros almacenados en la base de datos
    List<Map<String, dynamic>> lastFiveRecords = await _getLastFiveRecords();

    // Crear un arreglo para almacenar los resultados exitosos
    List<Map<String, dynamic>> successfulResults = [];

    // Iterar sobre los registros pendientes y enviarlos al servidor
    for (var record in lastFiveRecords) {
      try {
        // Preparar los datos para enviar en formato JSON
        var data = {
          'title': [{'value': '${record['tcNumber']}_${record['unixTime']}' }],
          'type': [{'target_id': 'disponibilidad_de_servicio'}],
          "field_latitud": [{"value": record['latitude'].toString()}],
          "field_longitud": [{"value": record['longitude'].toString()}],
          "field_status_code": [{"value": record['statusCode'].toString()}],
          "field_tc": [{"value": record['tcNumber']}],
          "field_unix": [{"value": record['unixTime'].toString()}]
        };

        // Definir la URL del endpoint de la API
        var apiUrl = 'http://24.199.103.244:8051/node?_format=json';

        // Crear una cadena de autenticación básica
        var username = 'collectdata';
        var password = '1q2w3e4r5t//';
        var authString = '$username:$password';
        var bytes = utf8.encode(authString);
        var base64Str = base64.encode(bytes);

        // Realizar una solicitud POST al endpoint de la API
        var response = await http.post(
          Uri.parse(apiUrl),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Authorization': 'Basic $base64Str',
          },
          body: jsonEncode(data),
        );

        // Verificar si la solicitud POST fue exitosa
        if (response.statusCode == 201) {
          print('Registro enviado con éxito: ${record['tcNumber']}_${record['unixTime']}');
          successfulResults.add(record); // Agregar el registro exitoso al arreglo
        } else {
          print('Error al enviar registro: ${record['tcNumber']}_${record['unixTime']}. Código de estado: ${response.statusCode}');
        }
      } catch (e) {
        print('Error al enviar registro: ${record['tcNumber']}_${record['unixTime']}. Error: $e');
      }
    }

    // Eliminar los registros exitosos del arreglo _pendingRecords
    for (var successfulResult in successfulResults) {
      _pendingRecords.remove(successfulResult);
    }

    print('Registros pendientes enviados con éxito.');

    // Limpia la lista de registros pendientes después de enviarlos
    _pendingRecords.clear();
  }


  void _showTCNumberInput() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        TextEditingController tcController = TextEditingController();
        return AlertDialog(
          title: const Text('Ingrese su número de TC'),
          content: TextField(
            controller: tcController,
            decoration: const InputDecoration(
              hintText: 'Ingrese su número de TC aquí',
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () async {
                final String input = tcController.text;
                if (input.isNotEmpty) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('tcNumber', input);
                  Navigator.of(context).pop();
                  setState(() {
                    tcNumber = input;
                  });
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _requestPermissions() async {
    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      print('Location permission not granted');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        tcNumber != null ? 'Su número de TC es $tcNumber' : 'Por favor, ingrese su número de TC',
        style: TextStyle(color: Colors.white, fontSize: 24),
        textAlign: TextAlign.center,
      ),
    );
  }
}
