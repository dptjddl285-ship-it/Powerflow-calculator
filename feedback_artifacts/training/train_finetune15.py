"""Conservative fine-tuning experiment; output stays under feedback_artifacts."""

from ultralytics import YOLO


model = YOLO("runs/detect/backend_api/auto_tune_runs/finetune_12_clean20_aug640/weights/best.pt")
model.train(
    data="backend_api/icon_recognition/configs/auto_tune_yolo_clean_02.yaml",
    epochs=8,
    patience=8,
    batch=1,
    imgsz=640,
    device="cpu",
    workers=0,
    project="feedback_artifacts/training",
    name="finetune15_diagram_conservative",
    exist_ok=True,
    seed=2,
    deterministic=True,
    lr0=0.001,
    mosaic=0.25,
    close_mosaic=4,
    erasing=0.1,
    fliplr=0.5,
)
