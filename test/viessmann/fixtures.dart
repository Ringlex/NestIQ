import 'package:nestiq/viessmann/viessmann_models.dart';

// Struktury odpowiedzi odtwarzają wynik tool/viessmann/probe.py z prawdziwego
// pieca Vitodens 100-W (E3_Vitodens_050_08): te same funkcje, wartości i zakresy.

Map<String, dynamic> num_(num value, String unit) =>
    {'type': 'number', 'value': value, 'unit': unit};

Map<String, dynamic> str(String value) => {'type': 'string', 'value': value};

Map<String, dynamic> flag(bool value) => {'type': 'boolean', 'value': value};

Map<String, dynamic> feat(
  String name, {
  Map<String, dynamic> props = const {},
  Map<String, dynamic> commands = const {},
}) =>
    {
      'feature': name,
      'isEnabled': true,
      'isReady': true,
      'properties': props,
      'commands': commands,
    };

Map<String, dynamic> cmd(String feature, String name,
        {Map<String, dynamic> params = const {}, bool executable = true}) =>
    {
      'uri':
          'https://api.viessmann-climatesolutions.com/iot/v2/features/installations/I/gateways/G/devices/0/features/$feature/commands/$name',
      'name': name,
      'isExecutable': executable,
      'params': params,
    };

Map<String, dynamic> summary(
        num day, num week, num month, num lastMonth, num year, String unit) =>
    {
      'currentDay': num_(day, unit),
      'lastSevenDays': num_(week, unit),
      'currentMonth': num_(month, unit),
      'lastMonth': num_(lastMonth, unit),
      'currentYear': num_(year, unit),
    };

/// Funkcje pieca jak w odpowiedzi API.
List<Map<String, dynamic>> vitodensFeatures({
  num dhwTarget = 48,
  String dhwMode = 'comfort',
  String heatingMode = 'heating',
  num circuitTemperature = 31,
}) =>
    [
      feat('device.lock.malfunction', props: {'active': flag(false)}),
      feat('device.messages.status.raw', props: {
        'entries': {
          'type': 'array',
          'value': [
            {
              'errorCode': 'S.6',
              'timestamp': '2026-10-27T16:33:03.000Z',
              'priority': 'status'
            },
            {
              'errorCode': 'S.1',
              'timestamp': '2026-10-10T15:03:47.000Z',
              'priority': 'status'
            },
          ],
        },
      }),
      feat('heating.boiler.sensors.temperature.commonSupply',
          props: {'value': num_(50.7, 'celsius'), 'status': str('connected')}),
      feat('heating.boiler.temperature', props: {'value': num_(20, 'celsius')}),
      feat('heating.boiler.pumps.internal.target',
          props: {'value': num_(0, 'percent')}),
      feat('heating.burners.0', props: {'active': flag(false)}),
      feat('heating.burners.0.modulation',
          props: {'value': num_(0, 'percent')}),
      feat('heating.burners.0.statistics',
          props: {'hours': num_(700, 'hour'), 'starts': num_(21719, '')}),
      feat('heating.circuits.0.operating.modes.active', props: {
        'value': str(heatingMode)
      }, commands: {
        'setMode': cmd('heating.circuits.0.operating.modes.active', 'setMode',
            params: {
              'mode': {
                'type': 'string',
                'required': true,
                'constraints': {
                  'enum': ['heating', 'standby']
                },
              },
            }),
      }),
      feat('heating.circuits.0.operating.programs.active',
          props: {'value': str('normalEnergySaving')}),
      feat('heating.circuits.0.operating.programs.normal', props: {
        'active': flag(false),
        'temperature': num_(circuitTemperature, 'celsius')
      }, commands: {
        'setTemperature': cmd(
            'heating.circuits.0.operating.programs.normal', 'setTemperature',
            params: {
              'targetTemperature': {
                'type': 'number',
                'required': true,
                'constraints': {'min': 2, 'max': 80, 'stepping': 1},
              },
            }),
      }),
      feat('heating.circuits.0.temperature.levels',
          props: {'min': num_(20, 'celsius'), 'max': num_(82, 'celsius')}),
      feat('heating.circuits.0.sensors.temperature.supply',
          props: {'value': num_(50.7, 'celsius'), 'status': str('connected')}),
      feat('heating.dhw.comfort', props: {'active': flag(true)}),
      feat('heating.dhw.operating.modes.active', props: {
        'value': str(dhwMode)
      }, commands: {
        'setMode':
            cmd('heating.dhw.operating.modes.active', 'setMode', params: {
          'mode': {
            'type': 'string',
            'required': true,
            'constraints': {
              'enum': ['comfort', 'eco', 'off']
            },
          },
        }),
      }),
      feat('heating.dhw.sensors.temperature.hotWaterStorage',
          props: {'value': num_(49.6, 'celsius'), 'status': str('connected')}),
      feat('heating.dhw.temperature.main', props: {
        'value': num_(dhwTarget, 'celsius')
      }, commands: {
        'setTargetTemperature': cmd(
            'heating.dhw.temperature.main', 'setTargetTemperature',
            params: {
              'temperature': {
                'type': 'number',
                'required': true,
                'constraints': {'min': 30, 'max': 60, 'stepping': 1},
              },
            }),
      }),
      feat('heating.gas.consumption.summary.dhw',
          props: summary(0.4, 4.3, 13.7, 12.9, 238.7, 'cubicMeter')),
      feat('heating.gas.consumption.summary.heating',
          props: summary(1.5, 3.6, 8.7, 0, 325.6, 'cubicMeter')),
      feat('heating.heat.production.summary.dhw',
          props: summary(4, 43, 137.2, 129.2, 2387.8, 'kilowattHour')),
      feat('heating.heat.production.summary.heating',
          props: summary(15, 36, 87, 0, 3256.9, 'kilowattHour')),
      // Funkcje bez wartości, bo czujników nie podłączono (jak w prawdziwym piecu).
      feat('heating.sensors.temperature.outside'),
      feat('heating.circuits.0.sensors.temperature.room'),
      feat('heating.sensors.pressure.supply',
          props: {'status': str('notConnected')}),
    ];

Map<String, dynamic> installations() => {
      'data': [
        {
          'id': 3300000006,
          'description': 'Dom',
          'gateways': [
            {
              'serial': '7000000051',
              'gatewayType': 'TCU10x_Vitodens_SE_S1',
              'devices': [
                {
                  'id': 'gateway',
                  'modelId': 'E3_TCU41_x08',
                  'deviceType': 'tcu',
                  'status': 'Online'
                },
                {
                  'id': '0',
                  'modelId': 'E3_Vitodens_050_08',
                  'deviceType': 'heating',
                  'status': 'Online'
                },
              ],
            },
          ],
        },
      ],
    };

const testDevice = ViessmannDeviceRef(
  installationId: 'I',
  gatewaySerial: 'G',
  deviceId: '0',
  modelId: 'E3_Vitodens_050_08',
);
