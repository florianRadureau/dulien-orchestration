import { ComponentFixture, TestBed } from '@angular/core/testing';
import { AlerteTestComponent } from './alerte-test.component';
import { DebugElement } from '@angular/core';
import { By } from '@angular/platform-browser';

describe('AlerteTestComponent', () => {
  let component: AlerteTestComponent;
  let fixture: ComponentFixture<AlerteTestComponent>;
  let debugElement: DebugElement;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [AlerteTestComponent]
    }).compileComponents();

    fixture = TestBed.createComponent(AlerteTestComponent);
    component = fixture.componentInstance;
    debugElement = fixture.debugElement;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('should display alert message "Alerte Orchestrateur"', () => {
    const messageElement = debugElement.query(By.css('.alerte-message'));
    expect(messageElement).toBeTruthy();
    expect(messageElement.nativeElement.textContent).toContain('Alerte Orchestrateur');
  });

  it('should have red background color', () => {
    const containerElement = debugElement.query(By.css('.alerte-container'));
    expect(containerElement).toBeTruthy();
    const styles = getComputedStyle(containerElement.nativeElement);
    expect(styles.backgroundColor).toBe('rgb(220, 53, 69)');
  });

  it('should display close button with X', () => {
    const closeButton = debugElement.query(By.css('.alerte-close'));
    expect(closeButton).toBeTruthy();
    expect(closeButton.nativeElement.textContent).toContain('✕');
  });

  it('should hide alert when close button is clicked', () => {
    const closeButton = debugElement.query(By.css('.alerte-close'));
    expect(closeButton).toBeTruthy();
    
    closeButton.nativeElement.click();
    fixture.detectChanges();
    
    expect(component.visible()).toBe(false);
    const containerElement = debugElement.query(By.css('.alerte-container'));
    expect(containerElement).toBeFalsy();
  });

  it('should initially be visible', () => {
    expect(component.visible()).toBe(true);
    const containerElement = debugElement.query(By.css('.alerte-container'));
    expect(containerElement).toBeTruthy();
  });

  it('should show alert when show() is called', () => {
    component.close();
    fixture.detectChanges();
    expect(component.visible()).toBe(false);
    
    component.show();
    fixture.detectChanges();
    expect(component.visible()).toBe(true);
    
    const containerElement = debugElement.query(By.css('.alerte-container'));
    expect(containerElement).toBeTruthy();
  });

  it('should have proper accessibility attributes', () => {
    const closeButton = debugElement.query(By.css('.alerte-close'));
    expect(closeButton).toBeTruthy();
    expect(closeButton.nativeElement.getAttribute('aria-label')).toBe('Fermer l\'alerte');
  });
});