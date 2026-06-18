import json
import os
import pandas as pd
import numpy as np
from scipy.spatial import distance_matrix
from scipy.ndimage import convolve, zoom
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
        geometries = [shape(feature['geometry']) for feature in data['features'] if 'geometry' in feature]
        combined = unary_union(geometries)
    else:
        # Fallback to direct geometry field
        combined = shape(data['geometry'])
    # Simplify to reduce complexity while preserving topology
    return combined.simplify(0.005, preserve_topology=True)

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

import urllib.request

def fetch_base_temperature(lat, lng):
    try:
        url = f"https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lng}&current=temperature_2m"
        req = urllib.request.Request(url, headers={'User-Agent': 'Treecon/1.0'})
        with urllib.request.urlopen(req, timeout=5) as response:
            data = json.loads(response.read().decode())
            return float(data['current']['temperature_2m'])
    except Exception as e:
        print(f"Error fetching temperature from API: {e}. Defaulting to 28.0°C.")
        return 28.0

def generate_elevation_grid(ny, nx, min_lng, max_lng, min_lat, max_lat):
    base_dir = os.path.dirname(os.path.abspath(__file__))
    cache_path = os.path.join(base_dir, "philippines_elevation.npy")
    
    if os.path.exists(cache_path):
        try:
            cached_grid = np.load(cache_path)
            if cached_grid.shape == (ny, nx):
                return cached_grid
            else:
                scale_y = ny / cached_grid.shape[0]
                scale_x = nx / cached_grid.shape[1]
                return zoom(cached_grid, (scale_y, scale_x), order=1)
        except Exception as e:
            print(f"Error loading cached elevation: {e}. Re-downloading...")
            
    # Download coarser grid: 9x9 points (81 points) to comply with Open-Meteo's 100 coordinate limit
    c_ny, c_nx = 9, 9
    lats = np.linspace(min_lat, max_lat, c_ny)
    lngs = np.linspace(min_lng, max_lng, c_nx)
    lng_mesh, lat_mesh = np.meshgrid(lngs, lats)
    flat_lats = lat_mesh.ravel()
    flat_lngs = lng_mesh.ravel()
    
    lat_str = ",".join([f"{lat:.4f}" for lat in flat_lats])
    lng_str = ",".join([f"{lng:.4f}" for lng in flat_lngs])
    
    try:
        url = f"https://api.open-meteo.com/v1/elevation?latitude={lat_str}&longitude={lng_str}"
        req = urllib.request.Request(url, headers={'User-Agent': 'Treecon/1.0'})
        with urllib.request.urlopen(req, timeout=15) as response:
            data = json.loads(response.read().decode())
            elevations = np.array(data['elevation']).reshape(c_ny, c_nx)
            elevations = np.maximum(0.0, elevations)
            
            # Cache the raw download locally
            np.save(cache_path, elevations)
            
            scale_y = ny / c_ny
            scale_x = nx / c_nx
            return zoom(elevations, (scale_y, scale_x), order=1)
    except Exception as e:
        print(f"Error downloading SRTM data: {e}. Falling back to simulated topography.")
        x = np.linspace(min_lng, max_lng, nx)
        y = np.linspace(min_lat, max_lat, ny)
        xx, yy = np.meshgrid(x, y)
        peak1 = 2954 * np.exp(-((xx - 125.4)**2 / 0.8 + (yy - 7.0)**2 / 0.8))
        peak2 = 2899 * np.exp(-((xx - 124.9)**2 / 0.6 + (yy - 8.1)**2 / 0.6))
        peak3 = 1500 * np.exp(-((xx - 122.5)**2 / 1.0 + (yy - 7.8)**2 / 1.0))
        elevation = peak1 + peak2 + peak3
        return np.maximum(0.0, elevation + 50.0)

def generate_stand_density_grid(elevation):
    density = 100.0 * np.exp(-((elevation - 600.0)**2 / 500000.0))
    np.random.seed(42)
    noise = np.random.uniform(-5.0, 5.0, size=elevation.shape)
    return np.clip(density + noise, 0.0, 100.0)

def generate_natural_veg_distance_grid(ny, nx):
    x = np.linspace(0, 10, nx)
    y = np.linspace(0, 10, ny)
    xx, yy = np.meshgrid(x, y)
    dist = np.sqrt((xx - 5.0)**2 + (yy - 5.0)**2) * 0.2
    return np.clip(dist, 0.0, 2.0)

def generate_understorey_diversity_grid(ny, nx):
    x = np.linspace(0, 4 * np.pi, nx)
    y = np.linspace(0, 4 * np.pi, ny)
    xx, yy = np.meshgrid(x, y)
    diversity = 2.0 + 1.0 * np.sin(xx/2) * np.cos(yy/2)
    return np.clip(diversity, 0.0, 4.0)

def get_temp_suitability(temp):
    suitability = np.exp(-((temp - 20.0)**2 / 30.0))
    return np.where((temp < 10.0) | (temp > 32.0), 0.0, suitability)

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
    
    # 1. Generate biological spread factor grids
    elevation_grid = generate_elevation_grid(ny, nx, min_lng, max_lng, min_lat, max_lat)
    stand_density_grid = generate_stand_density_grid(elevation_grid)
    veg_distance_grid = generate_natural_veg_distance_grid(ny, nx)
    understorey_diversity_grid = generate_understorey_diversity_grid(ny, nx)
    
    # Fetch base temperature (centered in Mindanao) and calculate local lapse rate
    base_temp = fetch_base_temperature(8.0, 125.0)
    temp_grid = base_temp - 0.0065 * elevation_grid
    
    # 2. Calculate daily suitability and susceptibility factors
    temp_suitability = get_temp_suitability(temp_grid)
    stand_density_modifier = stand_density_grid / 100.0
    veg_distance_modifier = 1.0 / (1.0 + veg_distance_grid)
    understorey_diversity_modifier = np.clip(1.0 - 0.15 * understorey_diversity_grid, 0.0, 1.0)
    
    # Combined susceptibility multiplier
    susceptibility_multiplier = temp_suitability * stand_density_modifier * veg_distance_modifier * understorey_diversity_modifier
    
    # 3x3 averaging kernel for 8-neighbor Moore neighborhood convolve
    kernel = np.array([
        [1.0, 1.0, 1.0],
        [1.0, 0.0, 1.0],
        [1.0, 1.0, 1.0]
    ]) / 8.0
    
    # Vectorized Cellular Automata spread iterations
    for _ in range(steps):
        avg_neighbor = convolve(current_grid, kernel, mode='constant', cval=0.0)
        current_grid = np.minimum(100.0, current_grid + avg_neighbor * spread_factor * susceptibility_multiplier)
        
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