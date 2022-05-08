import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart' as dotenv;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:web3dart/web3dart.dart';

Future main() async {
  await dotenv.load(fileName: ".env");
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Circles contract',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: MyHomePage(title: 'Circles contract'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key key, @required this.title}) : super(key: key);
  final String title;
  @override
  _MyHomePageState createState() => _MyHomePageState();
}

enum Mode { none, shownfts, mint }

class _MyHomePageState extends State<MyHomePage> {
  final CONTRACT_NAME = dotenv.env['CONTRACT_NAME'];
  final CONTRACT_ADDRESS = dotenv.env['CONTRACT_ADDRESS'];
  Mode mode = Mode.none; // or shownfts or mint
  http.Client httpClient = http.Client();
  Web3Client polygonClient;
  int tokenCounter = 0;
  String tokenSymbol = '';
  Uint8List mintedImage;
  int mintedCircleNo = 0;

  @override
  void initState() {
    final ALCHEMY_KEY = dotenv.env['ALCHEMY_KEY_TEST'];
    super.initState();
    httpClient = http.Client();
    polygonClient = Web3Client(ALCHEMY_KEY, httpClient);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: new Text("NFT Studio"),
            backgroundColor: Color.fromRGBO(103, 80, 200, 1),
            bottom: TabBar(
              tabs: [
                Tab(text: 'See NFTs',),
                Tab(text: 'Create NFT',),
              ],
            ),
          ),
          body: TabBarView(
            children: <Widget>[
              new Container(
                child: new Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 10, left: 7, right: 7),
                    child: showNFTs(tokenCounter),
                  ),
                ),
              ),
              new Container(
                child: new Scaffold(
                  body: Column(
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 10, left: 7, right: 7),
                        child: RaisedButton(
                          child: new Text('Select Image to mint'),
                          onPressed: () async {
                            uploadToIPFS().then((value) => {
                              if(value['status'] == 'success') {
                                mintStream(value['ipfsHashImage'], value['ipfsHashJson']).listen((dynamic event) {
                                  setState(() {
                                    mintedImage = event;
                                    tokenCounter++;
                                  });
                                })
                              }
                            });
                          },
                        ),
                      ),
                      showLatestMint()
                    ],
                  )
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget showNFTs(int tokenCounter) {
    return ListView.builder(
        itemCount: tokenCounter,
        itemBuilder: (_, int index) {
          return FutureBuilder<Map>(
            future: getImageFromToken(index),
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                return Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      Image.memory(
                        snapshot.data["png"],
                        width: 50,
                        height: 100,
                      ),
                      Text('${snapshot.data['name']}\n ${snapshot.data['description']}')
                    ],
                  ),
                );
              } else {
                return Text('\n\n\n   Retrieving image from IPFS ...\n\n\n');
              }
            },
          );
        });
  }

  Widget showLatestMint() {
    if (mintedImage == null)
      return Container();
    else
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Image.memory(
            mintedImage,
            width: 50,
            height: 100,
          ),
        ],
      );
  }

  Future<DeployedContract> getContract() async {
    final CONTRACT_NAME = dotenv.env['CONTRACT_NAME'];
    final CONTRACT_ADDRESS = dotenv.env['CONTRACT_ADDRESS'];
    String abi = await rootBundle.loadString("assets/abi.json"); //TODO update
    DeployedContract contract = DeployedContract(
      ContractAbi.fromJson(abi, CONTRACT_NAME),
      EthereumAddress.fromHex(CONTRACT_ADDRESS),
    );
    return contract;
  }

  Future<List<dynamic>> query(String functionName, List<dynamic> args) async {
    DeployedContract contract = await getContract();
    ContractFunction function = contract.function(functionName);
    List<dynamic> result = await polygonClient.call(contract: contract, function: function, params: args);
    return result;
  }

  Stream<dynamic> mintStream(String cid, String jsonURL) async* {
    try {
      final WALLET_PRIVATE_KEY = dotenv.env['WALLET_PRIVATE_KEY'];
      EthPrivateKey credential = EthPrivateKey.fromHex(WALLET_PRIVATE_KEY);
      DeployedContract contract = await getContract();
      ContractFunction function = contract.function('mint');
      String url = "https://ipfs.io/ipfs/$jsonURL";
      var results = await Future.wait([
        getImageFromGateway(cid),
        polygonClient.sendTransaction(
          credential,
          Transaction.callContract(
            maxGas: 6000000,
            // gasPrice: EtherAmount.inWei(BigInt.one),
            contract: contract,
            function: function,
            parameters: [url],
          ),
          fetchChainIdFromNetworkId: true,
          // chainId: null,
        ),
        Future.delayed(const Duration(seconds: 2))
      ]);
      yield results[0];
    } catch(e) {
     print(e.toString());
    }
  }

  Future<String> getTokenSymbol() async {
    if (tokenSymbol != '')
      return tokenSymbol;
    else {
      List<dynamic> result = await query('symbol', []);
      return result[0].toString();
    }
  }

  Future<int> gettokenCounter() async {
    if (tokenCounter >= 0)
      return tokenCounter;
    else {
      List<dynamic> result = await query('tokenCounter', []);
      return int.parse(result[0].toString());
    }
  }

  Future<Map> getImageFromToken(int token) async {
    List<dynamic> result = await query('tokenURI', [BigInt.from(token)]);
    String json = result[0]; //TODO change name, json is really an URL, not json
    Uint8List png = await getImageFromJSON_N(json);
    Map details = await getImageNameAndDescFromJSON(json);
    return {"png": png, "json": json, "name": details['name'], "description": details['description']};
  }

  Future<Uint8List> getImageFromJson(String json) async {
    final JSON_CID = dotenv.env['JSON_CID'];
    final IMAGES_CID = dotenv.env['IMAGES_CID'];
    String url = json
        .toString()
        .replaceFirst(r'ipfs://', r'https://ipfs.io/ipfs/')
        .replaceFirst(JSON_CID, IMAGES_CID)
        .replaceFirst('.json', '.png');
    var resp = await httpClient.get(Uri.parse(url));
    // TODO Add error checking - if(resp.statusCode!= 200) etc
    return Uint8List.fromList(resp.body.codeUnits);
  }

  Future<Uint8List> getImageFromGateway(String cid) async {
    String url = "https://ipfs.io/ipfs/$cid";
    var resp = await httpClient.get(Uri.parse(url));
    // TODO Add error checking - if(resp.statusCode!= 200) etc
    return Uint8List.fromList(resp.body.codeUnits);
  }

  Future<Uint8List> getImageFromJSON_N(String json) async {
    var resp = await httpClient.get(Uri.parse(json));
    var body = jsonDecode(resp.body);
    var image = await httpClient.get(Uri.parse(body['image']));
    // TODO Add error checking - if(resp.statusCode!= 200) etc
    return Uint8List.fromList(image.body.codeUnits);
  }

  Future<Map> getImageNameAndDescFromJSON(String json) async {
    var resp = await httpClient.get(Uri.parse(json));
    var body = jsonDecode(resp.body);
    return {
      "name": body['name'],
      "description": body['description']
    };
  }

  String generateRandomString(int length) {
    const _chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';
    Random _rnd = Random();
    return String.fromCharCodes(Iterable.generate(length, (_) => _chars.codeUnitAt(_rnd.nextInt(_chars.length))));
  }

  Future<Map<String, dynamic>> uploadToIPFS() async {
    FilePickerResult result = await FilePicker.platform.pickFiles();
    Directory appDocDir = await getApplicationDocumentsDirectory();
    String appDocPath = appDocDir.path;
    if(result != null) {
      try {
        var fileName = generateRandomString(15);
        File file = File(result.files.single.path);
        final pinataAPIKEY = dotenv.env['PINATA_API_KEY'];
        final pinataSECRETKEY = dotenv.env['PINATA_SECRET_KEY'];
        final uri = 'https://api.pinata.cloud/pinning/pinFileToIPFS';
        var request =  http.MultipartRequest(
            'POST', Uri.parse(uri)
        );
        request.headers['Content-Type'] = 'multipart/form-data';
        request.headers['pinata_api_key'] = pinataAPIKEY;
        request.headers['pinata_secret_api_key'] = pinataSECRETKEY;
        request.fields['name'] = fileName;
        request.files.add(await http.MultipartFile.fromPath('file', file.path));
        var response = await request.send();
        final res = await http.Response.fromStream(response);
        if(response.statusCode != 200) {
          return {
            'status': 'fail',
            'ipfsHashImage': '',
            'fileNameImage': '',
            'ipfsHashJson': '',
            'fileNameJson': ''
          };
        } else if(response.statusCode == 200) {
          var mainBody = jsonDecode(res.body);
          List<String> attributes = new List<String>();
          String jsonName = generateRandomString(15);
          String nftJson = '{"name": "$jsonName",' +
              '"description": "Man Glide Pictures",' +
              '"image": "https://ipfs.io/ipfs/${mainBody['IpfsHash']}",' +
              '"external_url": "https://opensea.io/manglide", ' +
              '"attributes": $attributes}';
          File jsonFile = File(appDocPath + '/' + jsonName + '.json');
          jsonFile.writeAsStringSync(nftJson);
          var requestJSON =  http.MultipartRequest(
              'POST', Uri.parse(uri)
          );
          requestJSON.headers['Content-Type'] = 'multipart/form-data';
          requestJSON.headers['pinata_api_key'] = pinataAPIKEY;
          requestJSON.headers['pinata_secret_api_key'] = pinataSECRETKEY;
          requestJSON.fields['name'] = jsonName;
          requestJSON.files.add(await http.MultipartFile.fromPath('file', jsonFile.path));
          var responseJSON = await requestJSON.send();
          final resJSON = await http.Response.fromStream(responseJSON);
          var jsonUploadResponse = jsonDecode(resJSON.body);
          if(resJSON.statusCode == 200) {
            return {
              'status': 'success',
              'ipfsHashImage': mainBody['IpfsHash'],
              'fileNameImage': fileName,
              'ipfsHashJson': jsonUploadResponse['IpfsHash'],
              'fileNameJson': jsonName
            };
          } else {
            return {
              'status': 'fail',
              'ipfsHashImage': '',
              'fileNameImage': '',
              'ipfsHashJson': '',
              'fileNameJson': ''
            };
          }
        }
      } catch(e) {
        return {
          'status': 'fail',
          'ipfsHashImage': '',
          'fileNameImage': '',
          'ipfsHashJson': '',
          'fileNameJson': ''
        };
      }
    } else {
      return {
        'status': 'fail',
        'ipfsHashImage': '',
        'fileNameImage': '',
        'ipfsHashJson': '',
        'fileNameJson': ''
      };
    }
  }
}