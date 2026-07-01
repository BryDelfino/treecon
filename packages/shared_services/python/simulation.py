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
    if val < 10.0:
        return "#4CAF50"  # Green: Healthy
    elif val < 25.0:
        return "#FFEB3B"  # Yellow: Low
    elif val < 50.0:
        return "#FF9800"  # Orange: Moderate
    elif val < 75.0:
        return "#F44336"  # Red: High
    else:
        return "#800000"  # Maroon: Severe

def run_idw(grid_resolution=0.12, power=2.0):
    base_dir = os.path.dirname(os.path.abspath(__file__))
    csv_path = os.path.join(base_dir, "..", "..", "..", "tulod_falcata_spatial_data.csv")
    
    df = pd.read_csv(csv_path)
    points = df[['longitude', 'latitude']].values
    values = df['severity_index_pct'].values
    
    min_lng, max_lng = df['longitude'].min() - 0.2, df['longitude'].max() + 0.2
    min_lat, max_lat = df['latitude'].min() - 0.2, df['latitude'].max() + 0.2
    
    boundary = load_boundary()
    min_lng, min_lat, max_lng, max_lat = boundary.bounds
    
    # Target resolution of ~0.05 degrees per cell (matching original resolution)
    resolution = 0.05
    nx = int(np.ceil((max_lng - min_lng) / resolution))
    ny = int(np.ceil((max_lat - min_lat) / resolution))
    
    # Create a dense grid for smooth curve calculations
    grid_lng = np.linspace(min_lng, max_lng, nx)
    grid_lat = np.linspace(min_lat, max_lat, ny)
    grid_lng_mesh, grid_lat_mesh = np.meshgrid(grid_lng, grid_lat)
    grid_points = np.vstack([grid_lng_mesh.ravel(), grid_lat_mesh.ravel()]).T
    
    # IDW matrix operations
    dist_mat = distance_matrix(grid_points, points)
    min_distances = dist_mat.min(axis=1)
    dist_mat = np.where(dist_mat == 0, 1e-12, dist_mat)
    
    weights = 1.0 / (dist_mat ** power)
    weights /= weights.sum(axis=1, keepdims=True)
    
    idw_values = np.dot(weights, values)
    # Apply distance threshold: if the nearest point is further than 1.5 degrees, force to 0.0
    idw_values = np.where(min_distances > 1.5, 0.0, idw_values).reshape(ny, nx)
    
    # Levels mapping for contour curves
    levels = [0.0, 10.0, 25.0, 50.0, 75.0, 100.0]
    
    fig, ax = plt.subplots()
    cs = ax.contourf(grid_lng_mesh, grid_lat_mesh, idw_values, levels=levels)
    
    features = []

    # Handle contour collections for both newer and older Matplotlib versions
    if hasattr(cs, 'collections') and cs.collections:
        contour_iter = cs.collections
    else:
        # Older versions: use allsegs (list of segments per level)
        contour_iter = None

    if contour_iter is not None:
        for level_idx, collection in enumerate(contour_iter):
            val_lower = levels[level_idx]
            val_upper = levels[level_idx + 1]
            color = get_color_for_value((val_lower + val_upper) / 2.0)

            paths = collection.get_paths()
            polygons = []
            for path in paths:
                for path_seg in path.to_polygons():
                    if len(path_seg) >= 3:
                        poly = Polygon(path_seg)
                        if not poly.is_valid:
                            poly = poly.buffer(0)
                        if poly.is_valid and not poly.is_empty:
                            polygons.append(poly)

            if polygons:
                merged_poly = unary_union(polygons)
                clipped_poly = _filter_polygons(_safe_intersection(merged_poly, boundary))
                if clipped_poly is not None and not clipped_poly.is_empty:
                    features.append(geojson.Feature(
                        geometry=clipped_poly,
                        properties={
                            "value_range": f"{val_lower}-{val_upper}",
                            "color": color
                        }
                    ))
    else:
        # Fallback using allsegs (list of segments per level)
        for level_idx, segs in enumerate(cs.allsegs):
            val_lower = levels[level_idx]
            val_upper = levels[level_idx + 1]
            color = get_color_for_value((val_lower + val_upper) / 2.0)

            polygons = []
            for seg in segs:
                if len(seg) >= 3:
                    poly = Polygon(seg)
                    if not poly.is_valid:
                        poly = poly.buffer(0)
                    if poly.is_valid and not poly.is_empty:
                        polygons.append(poly)

            if polygons:
                merged_poly = unary_union(polygons)
                clipped_poly = _filter_polygons(_safe_intersection(merged_poly, boundary))
                if clipped_poly is not None and not clipped_poly.is_empty:
                    features.append(geojson.Feature(
                        geometry=clipped_poly,
                        properties={
                            "value_range": f"{val_lower}-{val_upper}",
                            "color": color
                        }
                    ))
    plt.close(fig)
    return geojson.FeatureCollection(features)

def run_ca_simulation(steps=5, grid_resolution=0.12, spread_factor=0.08):
    base_dir = os.path.dirname(os.path.abspath(__file__))
    csv_path = os.path.join(base_dir, "..", "..", "..", "tulod_falcata_spatial_data.csv")
    
    df = pd.read_csv(csv_path)
    points = df[['longitude', 'latitude']].values
    values = df['severity_index_pct'].values
    
    boundary = load_boundary()
    min_lng, min_lat, max_lng, max_lat = boundary.bounds
    
    # Target resolution of ~0.05 degrees per cell (matching original Mindanao resolution)
    resolution = 0.05
    nx = int(np.ceil((max_lng - min_lng) / resolution))
    ny = int(np.ceil((max_lat - min_lat) / resolution))
    
    grid_lng = np.linspace(min_lng, max_lng, nx)
    grid_lat = np.linspace(min_lat, max_lat, ny)
    
    grid_lng_mesh, grid_lat_mesh = np.meshgrid(grid_lng, grid_lat)
    grid_points = np.vstack([grid_lng_mesh.ravel(), grid_lat_mesh.ravel()]).T
    
    dist_mat = distance_matrix(grid_points, points)
    min_distances = dist_mat.min(axis=1)
    dist_mat = np.where(dist_mat == 0, 1e-12, dist_mat)
    weights = 1.0 / (dist_mat ** 2.0)
    weights /= weights.sum(axis=1, keepdims=True)
    
    initial_values = np.dot(weights, values)
    # Apply distance threshold of 1.5 degrees to avoid global average in far regions
    initial_values = np.where(min_distances > 1.5, 0.0, initial_values).reshape(ny, nx)
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
        
    # Generate contour bands
    levels = [0.0, 10.0, 25.0, 50.0, 75.0, 100.0]
    
    fig, ax = plt.subplots()
    cs = ax.contourf(grid_lng_mesh, grid_lat_mesh, current_grid, levels=levels)
    
    features = []
    
    # Handle contour collections for both newer and older Matplotlib versions
    if hasattr(cs, 'collections') and cs.collections:
        contour_iter = cs.collections
    else:
        contour_iter = None

    if contour_iter is not None:
        for level_idx, collection in enumerate(contour_iter):
            val_lower = levels[level_idx]
            val_upper = levels[level_idx + 1]
            color = get_color_for_value((val_lower + val_upper) / 2.0)

            paths = collection.get_paths()
            polygons = []
            for path in paths:
                for path_seg in path.to_polygons():
                    if len(path_seg) >= 3:
                        poly = Polygon(path_seg)
                        if not poly.is_valid:
                            poly = poly.buffer(0)
                        if poly.is_valid and not poly.is_empty:
                            polygons.append(poly)

            if polygons:
                merged_poly = unary_union(polygons)
                clipped_poly = _filter_polygons(_safe_intersection(merged_poly, boundary))
                if clipped_poly is not None and not clipped_poly.is_empty:
                    features.append(geojson.Feature(
                        geometry=clipped_poly,
                        properties={
                            "value_range": f"{val_lower}-{val_upper}",
                            "color": color
                        }
                    ))
    else:
        # Fallback using allsegs (list of segments per level)
        for level_idx, segs in enumerate(cs.allsegs):
            val_lower = levels[level_idx]
            val_upper = levels[level_idx + 1]
            color = get_color_for_value((val_lower + val_upper) / 2.0)

            polygons = []
            for seg in segs:
                if len(seg) >= 3:
                    poly = Polygon(seg)
                    if not poly.is_valid:
                        poly = poly.buffer(0)
                    if poly.is_valid and not poly.is_empty:
                        polygons.append(poly)

            if polygons:
                merged_poly = unary_union(polygons)
                clipped_poly = _filter_polygons(merged_poly.intersection(boundary))
                if clipped_poly is not None and not clipped_poly.is_empty:
                    features.append(geojson.Feature(
                        geometry=clipped_poly,
                        properties={
                            "value_range": f"{val_lower}-{val_upper}",
                            "color": color
                        }
                    ))
                
    plt.close(fig)
    return geojson.FeatureCollection(features)

def run_kriging(grid_resolution=0.12):
    base_dir = os.path.dirname(os.path.abspath(__file__))
    csv_path = os.path.join(base_dir, "..", "..", "..", "tulod_falcata_spatial_data.csv")
    
    df = pd.read_csv(csv_path)
    df = df.dropna(subset=['longitude', 'latitude', 'severity_index_pct']).drop_duplicates(subset=['longitude', 'latitude'])
    x = df['longitude'].values
    y = df['latitude'].values
    z = df['severity_index_pct'].values
    
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
    
    levels = [0.0, 10.0, 25.0, 50.0, 75.0, 100.0]
    
    fig, ax = plt.subplots()
    cs = ax.contourf(grid_lng_mesh, grid_lat_mesh, kriging_values, levels=levels)
    
    features = []
    
    if hasattr(cs, 'collections') and cs.collections:
        contour_iter = cs.collections
    else:
        contour_iter = None

    if contour_iter is not None:
        for level_idx, collection in enumerate(contour_iter):
            val_lower = levels[level_idx]
            val_upper = levels[level_idx + 1]
            color = get_color_for_value((val_lower + val_upper) / 2.0)

            paths = collection.get_paths()
            polygons = []
            for path in paths:
                for path_seg in path.to_polygons():
                    if len(path_seg) >= 3:
                        poly = Polygon(path_seg)
                        if not poly.is_valid:
                            poly = poly.buffer(0)
                        if poly.is_valid and not poly.is_empty:
                            polygons.append(poly)

            if polygons:
                merged_poly = unary_union(polygons)
                clipped_poly = _filter_polygons(_safe_intersection(merged_poly, boundary))
                if clipped_poly is not None and not clipped_poly.is_empty:
                    features.append(geojson.Feature(
                        geometry=clipped_poly,
                        properties={
                            "value_range": f"{val_lower}-{val_upper}",
                            "color": color
                        }
                    ))
    else:
        for level_idx, segs in enumerate(cs.allsegs):
            val_lower = levels[level_idx]
            val_upper = levels[level_idx + 1]
            color = get_color_for_value((val_lower + val_upper) / 2.0)

            polygons = []
            for seg in segs:
                if len(seg) >= 3:
                    poly = Polygon(seg)
                    if not poly.is_valid:
                        poly = poly.buffer(0)
                    if poly.is_valid and not poly.is_empty:
                        polygons.append(poly)

            if polygons:
                merged_poly = unary_union(polygons)
                clipped_poly = _filter_polygons(_safe_intersection(merged_poly, boundary))
                if clipped_poly is not None and not clipped_poly.is_empty:
                    features.append(geojson.Feature(
                        geometry=clipped_poly,
                        properties={
                            "value_range": f"{val_lower}-{val_upper}",
                            "color": color
                        }
                    ))
                
    plt.close(fig)
    return geojson.FeatureCollection(features)

