"""
TransitFlow — Neo4j Seeder
Run once after starting Docker:
    python skeleton/seed_neo4j.py

Loads station and network data from train-mock-data/:
  - metro_stations.json         — city metro stations and adjacencies
  - national_rail_stations.json — national rail stations and adjacencies

Design your graph schema (node labels, relationship types, properties)
based on the data in these files, then implement the seed() function below.
"""

import json
import os
import sys

sys.path.insert(0, ".")

from neo4j import GraphDatabase
from skeleton.config import NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD

_DATA_DIR = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "train-mock-data")
)


def _load(filename):
    with open(os.path.join(_DATA_DIR, filename), encoding="utf-8") as f:
        return json.load(f)


def seed():
    metro_stations = _load("metro_stations.json")
    rail_stations  = _load("national_rail_stations.json")

    driver = GraphDatabase.driver(NEO4J_URI, auth=(NEO4J_USER, NEO4J_PASSWORD))
    with driver.session() as session:

        session.run("MATCH (n) DETACH DELETE n")
        print("  Cleared existing graph data")

        
        # TODO: Design your node labels and create metro station nodes.
        # Each station has: station_id, name, lines, and interchange info.
        # See metro_stations.json for the full data structure.
        session.run(
            """UNWIND $stations AS s
            MERGE (m:MetroStation {station_id: s.station_id})
            SET m.name = s.name,
                m.lines = s.lines,
                m.is_interchange_nr = s.is_interchange_national_rail,
                m.interchange_nr_id = s.interchange_national_rail_station_id
        """, stations=metro_stations)
        print("  Created MetroStation nodes")

        # TODO: Design your node labels and create national rail station nodes.
        # See national_rail_stations.json for the full data structure.
        session.run(
        """UNWIND $stations AS s
            MERGE (n:NationalRailStation {station_id: s.station_id})
            SET n.name = s.name,
                n.lines = s.lines,
                n.is_interchange_m = s.is_interchange_metro,
                n.interchange_m_id = s.interchange_metro_station_id
        """, stations=rail_stations)
        print("  Created NationalRailStation nodes")

        # TODO: Design your relationship types and create metro links.
        # Each station lists its adjacent_stations with line and travel_time_min.
        # Consider what properties to store on the relationship.
        session.run(
        """UNWIND $stations AS s
            UNWIND s.adjacent_stations AS adj
            MATCH (a:MetroStation {station_id: s.station_id})
            MATCH (b:MetroStation {station_id: adj.station_id})
            MERGE (a)-[r:METRO_LINK {line: adj.line}]->(b)
            SET r.travel_time_min = adj.travel_time_min
        """, stations=metro_stations)
        print("  Created METRO_LINK relationships")

        # TODO: Design your relationship types and create national rail links.
        session.run(
        """UNWIND $stations AS s
            UNWIND s.adjacent_stations AS adj
            MATCH (a:NationalRailStation {station_id: s.station_id})
            MATCH (b:NationalRailStation {station_id: adj.station_id})
            MERGE (a)-[r:RAIL_LINK {line: adj.line}]->(b)
            SET r.travel_time_min = adj.travel_time_min
        """, stations=rail_stations)

        print("  Created RAIL_LINK relationships")
        # TODO: Create interchange relationships between metro and rail stations.
        # Interchange info is in the is_interchange_national_rail field
        # of metro_stations.json.
        session.run(
        """UNWIND $stations AS s
            WITH s WHERE s.is_interchange_national_rail = true AND s.interchange_national_rail_station_id IS NOT NULL
            MATCH (m:MetroStation {station_id: s.station_id})
            MATCH (n:NationalRailStation {station_id: s.interchange_national_rail_station_id})
            MERGE (m)-[:INTERCHANGE_WITH]->(n)
            MERGE (n)-[:INTERCHANGE_WITH]->(m)
        """, stations=metro_stations)
        print("  Created INTERCHANGE_WITH relationships")

    driver.close()
    print("\nNeo4j graph seeded successfully.")
    print("   Open http://localhost:7475 to explore the graph.")


if __name__ == "__main__":
    print("Connecting to Neo4j...")
    seed()
