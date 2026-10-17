#include "detector.h"

#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect/barcode.hpp>

#include <algorithm>
#include <cmath>

namespace det {

std::vector<Cuadrilatero> detectar(const uint8_t* px, int ancho, int alto, int fila) {
  // Un detector por hilo: crearlo cuesta y no se comparte entre hilos.
  thread_local cv::barcode::BarcodeDetector detector;
  const cv::Mat gris(alto, ancho, CV_8UC1, const_cast<uint8_t*>(px), (size_t)fila);
  std::vector<cv::Point2f> puntos;
  std::vector<Cuadrilatero> salida;
  if (!detector.detectMulti(gris, puntos)) return salida;
  for (size_t i = 0; i + 3 < puntos.size(); i += 4) {
    Cuadrilatero q;
    for (int k = 0; k < 4; k++) {
      q[k * 2] = puntos[i + k].x;
      q[k * 2 + 1] = puntos[i + k].y;
    }
    salida.push_back(q);
  }
  return salida;
}

Recorte enderezar(const uint8_t* px, int ancho, int alto, int fila, const Cuadrilatero& q) {
  std::vector<cv::Point2f> pts;
  for (int k = 0; k < 4; k++) pts.emplace_back(q[k * 2], q[k * 2 + 1]);
  cv::RotatedRect r = cv::minAreaRect(pts);
  float w = r.size.width, h = r.size.height, angulo = r.angle;
  // El lado largo queda horizontal (barras verticales).
  if (w < h) {
    std::swap(w, h);
    angulo += 90;
  }
  // Codigos chicos: se amplian para que cada barra tenga mas pixeles.
  const float escala = w < 260 ? 2.0f : 1.0f;
  // Margen: la deteccion suele quedar justa sobre las barras; zxing necesita
  // la zona blanca a los costados (y algo arriba/abajo).
  const float mw = w * 0.18f + 12, mh = h * 0.25f + 8;
  const int W = (int)((w + 2 * mw) * escala), H = (int)((h + 2 * mh) * escala);

  cv::Mat M = cv::getRotationMatrix2D(r.center, angulo, escala);
  M.at<double>(0, 2) += W / 2.0 - r.center.x;
  M.at<double>(1, 2) += H / 2.0 - r.center.y;

  const cv::Mat src(alto, ancho, CV_8UC1, const_cast<uint8_t*>(px), (size_t)fila);
  Recorte rec;
  rec.img = prep::Gris{W, H, std::vector<uint8_t>((size_t)W * H)};
  cv::Mat dst(H, W, CV_8UC1, rec.img.px.data());
  cv::warpAffine(src, dst, M, dst.size(), cv::INTER_LINEAR, cv::BORDER_REPLICATE);

  cv::Mat inv;
  cv::invertAffineTransform(M, inv);
  rec.a = (float)inv.at<double>(0, 0);
  rec.b = (float)inv.at<double>(0, 1);
  rec.tx = (float)inv.at<double>(0, 2);
  rec.c = (float)inv.at<double>(1, 0);
  rec.d = (float)inv.at<double>(1, 1);
  rec.ty = (float)inv.at<double>(1, 2);
  return rec;
}

prep::Gris clahe(const prep::Gris& img) {
  thread_local cv::Ptr<cv::CLAHE> ecualizador = cv::createCLAHE(3.0, cv::Size(4, 4));
  prep::Gris salida{img.ancho, img.alto, std::vector<uint8_t>(img.px.size())};
  const cv::Mat src(img.alto, img.ancho, CV_8UC1, const_cast<uint8_t*>(img.px.data()));
  cv::Mat dst(img.alto, img.ancho, CV_8UC1, salida.px.data());
  ecualizador->apply(src, dst);
  return salida;
}

} // namespace det
