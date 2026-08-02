# -----------------------------
# 🔹 Import Python libraries
# -----------------------------
from flask import Flask, request, jsonify         # สำหรับสร้าง web API
from flask_cors import CORS                       # เพื่อเปิด CORS ให้สามารถเรียกจาก front-end ได้
import keras                                      # สำหรับโหลดและใช้งาน Keras model
import numpy as np                                # สำหรับจัดการข้อมูลในรูปแบบ array
from PIL import Image                             # สำหรับเปิดและประมวลผลรูปภาพ
import io                                         # สำหรับอ่านไบต์ข้อมูลรูปภาพ

# -----------------------------
# 🔹 Configuration
# -----------------------------
app = Flask(__name__) # สร้าง Flask app เพื่อใช้สร้าง API
CORS(app)  # เปิดใช้งาน CORS เพื่อให้ front-end เรียก API ได้
MODEL_PATH = "model/cnn_celeb.keras" # ที่เก็บโมเดลที่ train ไว้
LABEL_PATH = "model/cnn_label_index.txt" # ที่เก็บ class labels

# -----------------------------
# 🔹 Load ML model & Class Labels at startup
# -----------------------------
try:
    model = keras.models.load_model(MODEL_PATH)   # โหลดโมเดล Keras
except Exception as e:
    raise RuntimeError(f"Failed to load model: {e}")  # ถ้าโหลดไม่สำเร็จ ให้หยุดโปรแกรมพร้อมข้อความ

# โหลด class labels
labels = {}
try:
    with open(LABEL_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and ":" in line:
                name, idx = line.split(":")
                labels[int(idx.strip())] = name.strip()
except Exception as e:
    raise RuntimeError(f"Failed to load labels: {e}")

# -----------------------------
# 🔹 Celeb Prediction API
# -----------------------------
@app.route("/api/celeb", methods=["POST"])
def predict_celeb():
    try:
        # รับข้อมูลรูปภาพจาก request
        file = request.files.get("image") or request.files.get("file")
        if not file:
            return jsonify({
                "status": False,
                "error": "Missing image file. Please upload an image using field name 'image' or 'file'."
            }), 400

        # โหลดรูปภาพด้วย PIL
        try:
            image_bytes = file.read()
            img = Image.open(io.BytesIO(image_bytes))
        except Exception as e:
            return jsonify({
                "status": False,
                "error": "Invalid image file. Could not parse the uploaded file.",
                "detail": str(e)
            }), 400

        # แปลงรูปภาพเป็น RGB และปรับขนาดให้เป็น 224x224 ตามที่โมเดลต้องการ
        img = img.convert("RGB")
        img = img.resize((224, 224))

        # แปลงเป็น numpy array, ทำการ normalize (หาร 255.0) และขยายมิติข้อมูลสำหรับโมเดล
        img_array = np.array(img).astype("float32") / 255.0
        img_array = np.expand_dims(img_array, axis=0)

        # ทำนายผลด้วยโมเดล Keras
        predictions = model.predict(img_array)

        # หาคลาสที่มีค่าความมั่นใจสูงที่สุด
        predicted_idx = int(np.argmax(predictions[0]))
        predicted_name = labels.get(predicted_idx, "Unknown")
        confidence = float(predictions[0][predicted_idx])

        # สร้างลิสต์ผลทำนายของดาราทั้งหมดเรียงตามความมั่นใจ (จากมากไปน้อย) เพื่อเพิ่มคุณภาพของ API
        all_predictions = []
        for idx, conf in enumerate(predictions[0]):
            all_predictions.append({
                "label": labels.get(idx, f"Class {idx}"),
                "confidence": float(conf)
            })
        all_predictions = sorted(all_predictions, key=lambda x: x["confidence"], reverse=True)

        # ส่งผลลัพธ์กลับในรูป JSON
        return jsonify({
            "status": True,
            "prediction": predicted_name,
            "confidence": confidence,
            "all_predictions": all_predictions
        })

    except Exception as e:
        # จัดการข้อผิดพลาดอื่น ๆ
        return jsonify({
            "status": False,
            "error": "An unexpected error occurred during prediction.",
            "detail": str(e)
        }), 500

# -----------------------------
# 🔹 Run API server
# -----------------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000, debug=True)