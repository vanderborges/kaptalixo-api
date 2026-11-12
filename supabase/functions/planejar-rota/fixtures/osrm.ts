// Fixture OSRM `trip` gravada a mao (3 coletas + origem). Modulo TS: evita leitura de arquivo nos testes.
export const tripTresColetas = {
  "code": "Ok",
  "waypoints": [
    {
      "waypoint_index": 0,
      "trips_index": 0,
      "hint": "fixture",
      "distance": 4.1,
      "name": "Rua A",
      "location": [-48.55, -27.59],
    },
    {
      "waypoint_index": 3,
      "trips_index": 0,
      "hint": "fixture",
      "distance": 3.2,
      "name": "Rua B",
      "location": [-48.5, -27.55],
    },
    {
      "waypoint_index": 1,
      "trips_index": 0,
      "hint": "fixture",
      "distance": 2.7,
      "name": "Rua C",
      "location": [-48.548, -27.588],
    },
    {
      "waypoint_index": 2,
      "trips_index": 0,
      "hint": "fixture",
      "distance": 5.0,
      "name": "Rua D",
      "location": [-48.53, -27.57],
    },
  ],
  "trips": [
    {
      "geometry": "pjfmCnxvfH_@a@yd@kg@uf@mh@",
      "legs": [
        {
          "distance": 310.4,
          "duration": 61.2,
          "summary": "Rua A",
          "weight": 61.2,
          "steps": [],
        },
        {
          "distance": 2850.9,
          "duration": 350.5,
          "summary": "Rua C",
          "weight": 350.5,
          "steps": [],
        },
        {
          "distance": 4120.0,
          "duration": 512.8,
          "summary": "Rua D",
          "weight": 512.8,
          "steps": [],
        },
      ],
      "weight_name": "routability",
      "weight": 924.5,
      "duration": 924.5,
      "distance": 7281.3,
    },
  ],
};

export const tripNenhumaRota = { code: "NoTrips", message: "No trips found" };
