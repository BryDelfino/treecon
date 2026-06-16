import json
import os
import pandas as pd
import numpy as np
from scipy.spatial import distance_matrix
from shapely.geometry import shape, Polygon, MultiPolygon
from shapely.ops import unary_union
import geojson

# Configure Matplotlib to run in headless/non-GUI mode
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

def load_boundary():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    json_path = os.path.join(base_dir, "..", "..", "..", "apps", "commander_web", "assets", "philippines.json")
    
    with open(json_path, 'r') as f:
        data = json.load(f)
    return shape(data['geometry']).simplify(0.005, preserve_topology=True)

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
    
    # Create a dense grid for smooth curve calculations
    grid_lng = np.linspace(min_lng, max_lng, 120)
    grid_lat = np.linspace(min_lat, max_lat, 120)
    grid_lng_mesh, grid_lat_mesh = np.meshgrid(grid_lng, grid_lat)
    grid_points = np.vstack([grid_lng_mesh.ravel(), grid_lat_mesh.ravel()]).T
    
    # IDW matrix operations
    dist_mat = distance_matrix(grid_points, points)
    dist_mat = np.where(dist_mat == 0, 1e-12, dist_mat)
    
    weights = 1.0 / (dist_mat ** power)
    weights /= weights.sum(axis=1, keepdims=True)
    
    idw_values = np.dot(weights, values).reshape(120, 120)
    
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
                clipped_poly = _filter_polygons(merged_poly.intersection(boundary))
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

def run_ca_simulation(steps=5, grid_resolution=0.12, spread_factor=0.08):
    base_dir = os.path.dirname(os.path.abspath(__file__))
    csv_path = os.path.join(base_dir, "..", "..", "..", "tulod_falcata_spatial_data.csv")
    
    df = pd.read_csv(csv_path)
    points = df[['longitude', 'latitude']].values
    values = df['severity_index_pct'].values
    
    min_lng, max_lng = df['longitude'].min() - 0.2, df['longitude'].max() + 0.2
    min_lat, max_lat = df['latitude'].min() - 0.2, df['latitude'].max() + 0.2
    
    boundary = load_boundary()
    
    # CA grid size
    grid_lng = np.linspace(min_lng, max_lng, 90)
    grid_lat = np.linspace(min_lat, max_lat, 90)
    
    nx, ny = len(grid_lng), len(grid_lat)
    grid_lng_mesh, grid_lat_mesh = np.meshgrid(grid_lng, grid_lat)
    grid_points = np.vstack([grid_lng_mesh.ravel(), grid_lat_mesh.ravel()]).T
    
    dist_mat = distance_matrix(grid_points, points)
    dist_mat = np.where(dist_mat == 0, 1e-12, dist_mat)
    weights = 1.0 / (dist_mat ** 2.0)
    weights /= weights.sum(axis=1, keepdims=True)
    
    initial_values = np.dot(weights, values).reshape(ny, nx)
    current_grid = initial_values.copy()
    
    # Cellular Automata spread iterations
    for _ in range(steps):
        next_grid = current_grid.copy()
        for y in range(ny):
            for x in range(nx):
                neighbors = []
                for dy in [-1, 0, 1]:
                    for dx in [-1, 0, 1]:
                        if dx == 0 and dy == 0:
                            continue
                        ny_idx, nx_idx = y + dy, x + dx
                        if 0 <= ny_idx < ny and 0 <= nx_idx < nx:
                            neighbors.append(current_grid[ny_idx, nx_idx])
                
                if neighbors:
                    avg_neighbor = sum(neighbors) / len(neighbors)
                    next_grid[y, x] = min(100.0, current_grid[y, x] + avg_neighbor * spread_factor)
        current_grid = next_grid
        
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
                clipped_poly = _filter_polygons(merged_poly.intersection(boundary))
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
