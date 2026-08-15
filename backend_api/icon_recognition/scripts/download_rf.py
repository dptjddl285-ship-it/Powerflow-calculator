import os
import glob
import shutil
from roboflow import Roboflow

def download_and_prepare():
    api_key = os.environ.get("ROBOFLOW_API_KEY")
    if not api_key:
        raise RuntimeError("Set ROBOFLOW_API_KEY before downloading a Roboflow dataset.")
    rf = Roboflow(api_key=api_key)
    project = rf.workspace("s-workspace-sa92u").project("ieee-symbol-detection")
    version = project.version(35)
    
    # Download dataset in YOLO format (contains both images and txt labels)
    dataset = version.download("yolov8")
    dataset_path = dataset.location
    print(f"Downloaded to {dataset_path}")

    # Create target directories
    test_img_dir = "test_images"
    labels_dir = "labels"
    os.makedirs(test_img_dir, exist_ok=True)
    os.makedirs(labels_dir, exist_ok=True)
    
    # Find all images
    image_patterns = [
        os.path.join(dataset_path, "**", "*.jpg"),
        os.path.join(dataset_path, "**", "*.jpeg"),
        os.path.join(dataset_path, "**", "*.png")
    ]
    
    all_images = []
    for pattern in image_patterns:
        all_images.extend(glob.glob(pattern, recursive=True))
        
    print(f"Found {len(all_images)} images in downloaded dataset.")
    
    # Clear existing files
    for f in glob.glob(os.path.join(test_img_dir, "*")): os.remove(f)
    for f in glob.glob(os.path.join(labels_dir, "*")): os.remove(f)

    # Move and rename pairs synchronously
    moved_count = 0
    for idx, img_path in enumerate(all_images, start=1):
        # The label file in YOLO format usually has the same basename but .txt extension
        # It's located in a 'labels' sibling folder to 'images' folder
        img_basename = os.path.basename(img_path)
        img_name_no_ext, ext = os.path.splitext(img_basename)
        
        # Determine the label path
        # YOLOv8 format: dataset/train/images/foo.jpg -> dataset/train/labels/foo.txt
        img_dir = os.path.dirname(img_path)
        parent_dir = os.path.dirname(img_dir)
        label_path = os.path.join(parent_dir, "labels", img_name_no_ext + ".txt")
        
        new_basename = f"test_image{idx}"
        dest_img_path = os.path.join(test_img_dir, new_basename + ext)
        dest_label_path = os.path.join(labels_dir, new_basename + ".txt")
        
        # Move image
        shutil.copy2(img_path, dest_img_path)
        
        # Move label if it exists (sometimes background images have no label file)
        if os.path.exists(label_path):
            shutil.copy2(label_path, dest_label_path)
        else:
            # Create an empty label file if none exists
            open(dest_label_path, 'a').close()
            
        moved_count += 1

    print(f"Successfully moved {moved_count} image/label pairs!")

    # Clean up the downloaded dataset folder
    shutil.rmtree(dataset_path)
    print("Cleaned up temporary dataset folder.")

if __name__ == '__main__':
    download_and_prepare()
