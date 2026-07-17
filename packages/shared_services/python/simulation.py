import json
import os
import pandas as pd
import numpy as np
from scipy.spatial import distance_matrix
from scipy.ndimage import convolve
from shapely.geometry import shape, Polygon, MultiPolygon
from shapely.ops import unary_union
import geojson
from pykrige.ok import OrdinaryKriging


# Configure Matplotlib to run in headless/non-GUI mode
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

def load_boundary():
    """Load the Philippines boundary geometry.
    The GeoJSON asset is a FeatureCollection containing multiple features.
    We combine all feature geometries into a single (multi)polygon and
    simplify it for faster spatial operations.
    """
    base_dir = os.path.dirname(os.path.abspath(__file__))
    json_path = os.path.join(base_dir, "philippines.json")
    if not os.path.exists(json_path):
        json_path = os.path.join(base_dir, "..", "..", "..", "apps", "commander_web", "assets", "philippines.json")
    
    with open(json_path, 'r') as f:
        data = json.load(f)
    # If the file is a FeatureCollection, union all geometries.
    if data.get('type') == 'FeatureCollection' and 'features' in data:
        geometries = []
        for feature in data['features']:
            if 'geometry' in feature:
                geom = shape(feature['geometry'])
                if not geom.is_valid:
                    geom = geom.buffer(0)
                geometries.append(geom)
        combined = unary_union(geometries)
    else:
        # Fallback to direct geometry field
        combined = shape(data['geometry'])
        if not combined.is_valid:
            combined = combined.buffer(0)
            
    if not combined.is_valid:
        combined = combined.buffer(0)
        
    # Simplify to reduce complexity while preserving topology
    simplified = combined.simplify(0.005, preserve_topology=True)
    if not simplified.is_valid:
        simplified = simplified.buffer(0)
    return simplified

def get_admin_features():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    json_path = os.path.join(base_dir, "philippines.json")
    if not os.path.exists(json_path):
        json_path = os.path.join(base_dir, "..", "..", "..", "apps", "commander_web", "assets", "philippines.json")
    
    with open(json_path, 'r') as f:
        data = json.load(f)
    
    features = []
    if data.get('type') == 'FeatureCollection' and 'features' in data:
        for feature in data['features']:
            if 'geometry' in feature:
                geom = shape(feature['geometry'])
                if not geom.is_valid:
                    geom = geom.buffer(0)
                
                features.append({
                    'geometry': geom,
                    'properties': feature.get('properties', {})
                })
    return features

def _filter_polygons(geom):
    if geom.is_empty:
        return None
    if geom.geom_type in ['Polygon', 'MultiPolygon']:
        return geom
    if geom.geom_type == 'GeometryCollection':
        polys = [g for g in geom.geoms if g.geom_type in ['Polygon', 'MultiPolygon']]
        if polys:
            return unary_union(polys)
    return None

def _safe_intersection(geom_a, geom_b):
    if not geom_a.is_valid:
        geom_a = geom_a.buffer(0)
    if not geom_b.is_valid:
        geom_b = geom_b.buffer(0)
    try:
        return geom_a.intersection(geom_b)
    except Exception:
        return geom_a.buffer(0.0001).intersection(geom_b.buffer(0.0001))

def get_color_for_value(val):
    if val == 0.0:
        return "#4CAF50"  # Green: Healthy
    elif val <= 10.0:
        return "#FFEB3B"  # Yellow: Low
    elif val <= 25.0:
        return "#FF9800"  # Orange: Moderate
    elif val <= 60.0:
        return "#F44336"  # Red: High
    else:
        return "#800000"  # Maroon: Critical

def run_ca_simulation(df, steps=5, grid_resolution=0.12, spread_factor=0.08):
    df = df.dropna(subset=['longitude', 'latitude', 'GSI'])
    # Kriging requires unique input coordinates (duplicates make the
    # covariance matrix singular), so it's fed a deduplicated subset.
    # Per-point forecasts below use the FULL set of rows instead, so that
    # two plantation records sharing the same coordinates each still get a
    # forecast anchored to their OWN GSI, not whichever row happened to
    # survive deduplication.
    df_unique = df.drop_duplicates(subset=['longitude', 'latitude'])
    x = df_unique['longitude'].values
    y = df_unique['latitude'].values
    z = df_unique['GSI'].values

    all_x = df['longitude'].values
    all_y = df['latitude'].values
    all_z = df['GSI'].values

    boundary = load_boundary()
    min_lng, min_lat, max_lng, max_lat = boundary.bounds
    
    # Target resolution of ~0.08 degrees per cell to balance Kriging performance
    resolution = 0.08
    nx = int(np.ceil((max_lng - min_lng) / resolution))
    ny = int(np.ceil((max_lat - min_lat) / resolution))
    
    gridx = np.linspace(min_lng, max_lng, nx)
    gridy = np.linspace(min_lat, max_lat, ny)
    grid_lng_mesh, grid_lat_mesh = np.meshgrid(gridx, gridy)
    
    ok = OrdinaryKriging(
        x, y, z,
        variogram_model='spherical',
        verbose=False,
        enable_plotting=False
    )
    
    kriging_values, ss = ok.execute('grid', gridx, gridy)
    kriging_values = np.clip(np.array(kriging_values), 0.0, 100.0)
    
    grid_points = np.vstack([grid_lng_mesh.ravel(), grid_lat_mesh.ravel()]).T
    points_filtered = np.column_stack((x, y))
    dist_mat = distance_matrix(grid_points, points_filtered)
    min_distances = dist_mat.min(axis=1).reshape(ny, nx)
    
    initial_values = np.where(min_distances > 1.5, 0.0, kriging_values)
    current_grid = initial_values.copy()
    
    # 3x3 averaging kernel for 8-neighbor Moore neighborhood convolve
    kernel = np.array([
        [1.0, 1.0, 1.0],
        [1.0, 0.0, 1.0],
        [1.0, 1.0, 1.0]
    ]) / 8.0
    
    # Vectorized Cellular Automata spread iterations
    for _ in range(steps):
        avg_neighbor = convolve(current_grid, kernel, mode='constant', cval=0.0)
        current_grid = np.minimum(100.0, current_grid + avg_neighbor * spread_factor)

    # Per-plantation-point forecast. We anchor each point to its OWN raw GSI
    # reading rather than the Kriging-interpolated grid value at its nearest
    # cell: Kriging is a smoothing interpolator, so a locally severe point
    # surrounded by milder neighbors can have a lower value at its nearest
    # grid cell than its own raw reading -- even before any spread iterations
    # run. Instead, we add the CA spread CONTRIBUTION (how much a cell grew
    # due to neighbor influence over `steps` iterations), which is always
    # >= 0 by construction, on top of the point's raw baseline. This
    # guarantees the forecast can never show a lower severity than the
    # point's own current reading.
    point_ix = np.clip(np.round((all_x - min_lng) / resolution).astype(int), 0, nx - 1)
    point_iy = np.clip(np.round((all_y - min_lat) / resolution).astype(int), 0, ny - 1)
    spread_delta = current_grid - initial_values  # elementwise >= 0
    point_spread_delta = spread_delta[point_iy, point_ix]
    point_forecast_values = np.minimum(100.0, all_z + point_spread_delta)
    point_forecasts = [
        {
            'longitude': float(lng_val),
            'latitude': float(lat_val),
            'severity_value': round(float(val), 2),
        }
        for lng_val, lat_val, val in zip(all_x, all_y, point_forecast_values)
    ]

    admin_features = get_admin_features()
    out_features = []

    for f in admin_features:
        geom = f['geometry']
        props = f['properties']

        centroid = geom.centroid

        ix = int(round((centroid.x - min_lng) / resolution))
        iy = int(round((centroid.y - min_lat) / resolution))

        ix = max(0, min(nx - 1, ix))
        iy = max(0, min(ny - 1, iy))

        val = float(current_grid[iy, ix])
        color = get_color_for_value(val)

        props['severity_value'] = round(val, 2)
        props['color'] = color

        out_features.append(geojson.Feature(
            geometry=geom,
            properties=props
        ))

    result = geojson.FeatureCollection(out_features)
    result['point_forecasts'] = point_forecasts
    return result

def run_kriging(df, grid_resolution=0.12):
    df = df.dropna(subset=['longitude', 'latitude', 'GSI']).drop_duplicates(subset=['longitude', 'latitude'])
    x = df['longitude'].values
    y = df['latitude'].values
    z = df['GSI'].values
    
    boundary = load_boundary()
    min_lng, min_lat, max_lng, max_lat = boundary.bounds
    
    # Target resolution of ~0.08 degrees per cell for Kriging performance balance
    resolution = 0.08
    nx = int(np.ceil((max_lng - min_lng) / resolution))
    ny = int(np.ceil((max_lat - min_lat) / resolution))
    
    gridx = np.linspace(min_lng, max_lng, nx)
    gridy = np.linspace(min_lat, max_lat, ny)
    grid_lng_mesh, grid_lat_mesh = np.meshgrid(gridx, gridy)
    
    ok = OrdinaryKriging(
        x, y, z,
        variogram_model='spherical',
        verbose=False,
        enable_plotting=False
    )
    
    kriging_values, ss = ok.execute('grid', gridx, gridy)
    kriging_values = np.clip(np.array(kriging_values), 0.0, 100.0)
    
    # Calculate distance mask to zero out cells far from sample points
    grid_points = np.vstack([grid_lng_mesh.ravel(), grid_lat_mesh.ravel()]).T
    points = np.column_stack((x, y))
    dist_mat = distance_matrix(grid_points, points)
    min_distances = dist_mat.min(axis=1).reshape(ny, nx)
    
    # Apply distance threshold of 1.5 degrees
    kriging_values = np.where(min_distances > 1.5, 0.0, kriging_values)
    
    admin_features = get_admin_features()
    out_features = []
    
    for f in admin_features:
        geom = f['geometry']
        props = f['properties']
        
        centroid = geom.centroid
        
        ix = int(round((centroid.x - min_lng) / resolution))
        iy = int(round((centroid.y - min_lat) / resolution))
        
        ix = max(0, min(nx - 1, ix))
        iy = max(0, min(ny - 1, iy))
        
        val = float(kriging_values[iy, ix])
        color = get_color_for_value(val)
        
        props['severity_value'] = round(val, 2)
        props['color'] = color
        
        out_features.append(geojson.Feature(
            geometry=geom,
            properties=props
        ))
        
    return geojson.FeatureCollection(out_features)

