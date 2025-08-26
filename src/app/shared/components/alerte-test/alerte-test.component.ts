import { Component, signal } from '@angular/core';
import { CommonModule } from '@angular/common';

@Component({
  selector: 'app-alerte-test',
  standalone: true,
  imports: [CommonModule],
  template: `
    @if (visible()) {
      <div class="alerte-container">
        <div class="alerte-message">Alerte Orchestrateur</div>
        <button class="alerte-close" (click)="close()" aria-label="Fermer l'alerte">✕</button>
      </div>
    }
  `,
  styles: [`
    .alerte-container {
      position: relative;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 16px;
      background-color: #dc3545;
      color: white;
      border-radius: 4px;
      box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
      margin: 16px 0;
      animation: slideIn 0.3s ease-out;
    }

    @keyframes slideIn {
      from {
        opacity: 0;
        transform: translateY(-10px);
      }
      to {
        opacity: 1;
        transform: translateY(0);
      }
    }

    .alerte-message {
      font-weight: 500;
      font-size: 16px;
    }

    .alerte-close {
      background: transparent;
      border: none;
      color: white;
      font-size: 24px;
      cursor: pointer;
      padding: 0;
      margin-left: 16px;
      width: 32px;
      height: 32px;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: opacity 0.2s;
    }

    .alerte-close:hover {
      opacity: 0.8;
    }

    .alerte-close:focus {
      outline: 2px solid white;
      outline-offset: 2px;
    }
  `]
})
export class AlerteTestComponent {
  visible = signal(true);

  close(): void {
    this.visible.set(false);
  }

  show(): void {
    this.visible.set(true);
  }
}