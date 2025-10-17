//
//  OverlayPanel.swift
//  MyTranslation
//
//  Created by sailor.m on 10/16/25.
//

import UIKit

final class OverlayPanel: UIView {
    private let titleLabel = UILabel()
    private let textLabel = UILabel()
    private let askButton = UIButton(type: .system)
    private let applyButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    var onAsk: (() -> Void)?
    var onApply: (() -> Void)?
    var onClose: (() -> Void)?
    // 배치 시 사용: 패널 최대 너비
    var maxWidth: CGFloat = 320

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        layer.cornerRadius = 12
        layer.masksToBounds = true

        // 반투명 블러 배경
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        titleLabel.font = .boldSystemFont(ofSize: 15)
        titleLabel.text = "선택된 문장"
        titleLabel.numberOfLines = 1

        textLabel.font = .systemFont(ofSize: 14)
        textLabel.numberOfLines = 3

        let h = UIStackView()
        h.axis = .horizontal
        h.spacing = 8
        h.distribution = .fillEqually

        askButton.setTitle("AI에 물어보기", for: .normal)
        applyButton.setTitle("적용", for: .normal)
        closeButton.setTitle("닫기", for: .normal)

        h.addArrangedSubview(askButton)
        h.addArrangedSubview(applyButton)

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(textLabel)

        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.alignment = .center
        bottom.spacing = 8
        bottom.addArrangedSubview(h)
        bottom.addArrangedSubview(closeButton)

        stack.addArrangedSubview(bottom)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        askButton.addTarget(self, action: #selector(onTapAsk), for: .touchUpInside)
        applyButton.addTarget(self, action: #selector(onTapApply), for: .touchUpInside)
        closeButton.addTarget(self, action: #selector(onTapClose), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(selectedText: String, improved: String?) {
        textLabel.text = improved ?? selectedText
        applyButton.isEnabled = (improved != nil)
        setNeedsLayout()
        layoutIfNeeded()
    }
    
    /// 클릭된 요소 rect(뷰포트 기준)에 맞춰 화면 내 적절한 위치로 배치
    func present(near rect: CGRect, in hostView: UIView, margin: CGFloat = 8) {
        // 사이즈 계산
        let targetWidth = min(maxWidth, hostView.bounds.width - 2*margin)
        let size = systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let panelW = min(size.width, targetWidth)
        let panelH = size.height

        // 기본 위치: target 위쪽에 띄우되, 공간 없으면 아래쪽
        var x = rect.minX
        var y = rect.minY - panelH - margin

        // 화면 경계 보정
        if y < margin {
            y = rect.maxY + margin
        }
        if x + panelW > hostView.bounds.width - margin {
            x = hostView.bounds.width - margin - panelW
        }
        if x < margin { x = margin }

        frame = CGRect(x: x, y: y, width: panelW, height: panelH)
        isHidden = false
    }

    @objc private func onTapAsk() { onAsk?() }
    @objc private func onTapApply() { onApply?() }
    @objc private func onTapClose() { onClose?() }
}
